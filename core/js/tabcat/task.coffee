# Methods for use by tasks, especially to record task data.
#
# Most of this code assumes that it will only be used by one task ever,
# since each new task is a separate HTML document with a separate page load.

@tabcat ?= {}
tabcat.task = {}


# by default, we attempt to upload a chunk of events every 5 seconds
DEFAULT_EVENT_LOG_SYNC_INTERVAL = 5000

# DB where we store patient and encounter docs
DATA_DB = 'tabcat-data'

# so we don't have to type window.localStorage in functions
localStorage = @localStorage


# The CouchDB document for this task. This stores information about the task as
# a whole. We can store this in memory because each task is a single page.
taskDoc = null

# An array of events recorded during the task (e.g. user clicked). These are
# are stored to CouchDB in chunks periodically. This is independent from
# tabcat.task.start()
eventLog = []

# This tracks where we are in the event log in terms of items that we've
# successfully stored in the DB
eventSyncStartIndex = 0

# This tracks where we are in the event log in terms of items that we've
# attempted to upload and MAY be stored on the server. Sections of eventLog
# log before this index should be considered read-only.
eventSyncEndIndex = 0

# The current xhr for an AJAX request to upload events (only one is allowed at
# a time).
eventSyncXHR = null

# ID of the timer for event uploads
eventSyncIntervalId = null



# Does the patient have the device? Call with an argument (true or false) to
# set whether the patient has device.
#
# tabcat.task.start() sets this to true unless you call it with the
# examinerAdministered option.
#
# The return-to-examiner.html page sets this back to false
tabcat.task.patientHasDevice = (value) ->
  if value?
    if value
      localStorage.patientHasDevice = 'true'
    else
      localStorage.removeItem('patientHasDevice')

  return (localStorage.patientHasDevice is 'true')


# Promise: Initialize the task. This does lots of things:
# - start automatically logging when the browser resizes
# - check if it's okay to continue (correct PHI, browser capabilities, etc)
# - create an initial task doc with start time, browser info, viewport,
#   patient code, etc.
#
# options:
# - eventLogSyncInterval: how often to upload chunks of the event log, in
#   milliseconds (default is 5 seconds). Set this to 0 to disable periodic
#   uploads.
# - examinerAdministered: should the examiner have the device before the task
#   starts?
# - trackViewport: should we log changes to the viewport in the event log?
#   (see tabcat.task.trackViewportInEventLog())
tabcat.task.start = _.once((options) ->
  # require user and encounter, but don't require user to be authenticated
  if not (tabcat.user.get() and tabcat.encounter.isOpen())
    tabcat.ui.requestLogin()

  taskDoc =
      _id: tabcat.couch.randomUUID()
      type: 'task'
      browser: tabcat.task.getBrowserInfo()
      clockLastStarted: tabcat.clock.lastStarted()
      encounterId: tabcat.encounter.getId()
      patientCode: tabcat.encounter.getPatientCode()
      startedAt: tabcat.clock.now()
      startViewport: tabcat.task.getViewportInfo()
      name: tabcat.task.getTaskName()
      user: tabcat.user.get()

  if options?.trackViewport
    tabcat.task.trackViewportInEventLog()

  # TODO: redirect to the return-to-examiner page if the patient has the device
  # and this is examiner-administered
  if not options?.examinerAdministered
    tabcat.task.patientHasDevice(true)

  # periodically upload chunks of the event log
  eventLogSyncInterval = (
    options?.eventLogSyncInterval ? DEFAULT_EVENT_LOG_SYNC_INTERVAL)

  if eventLogSyncInterval > 0
    eventSyncIntervalId = window.setInterval(
      tabcat.task.syncEventLog, eventLogSyncInterval)

  # create the task document on the server; we'll update it when
  # tabcat.task.finish() is called. This allows us to fail fast if there's
  # a problem with the server, and also to detect tasks that were started
  # but not finished.
  createTaskDoc = (additionalFields) ->
    $.extend(taskDoc, additionalFields)
    tabcat.db.putDoc(DATA_DB, taskDoc)

  # fetch login information and the task's design doc (.), and create
  # the task document, with some additional fields filled in
  $.when($.getJSON('.'), tabcat.config.get()).then(
    ([designDoc], config) ->
      additionalFields =
        version: designDoc?.kanso.config.version

      if config.limitedPHI
        additionalFields.limitedPHI =
          clockOffset: tabcat.clock.offset()

      createTaskDoc(additionalFields)
  )
)


# Promise (can't fail): upload the portion of the event log that has not
# already been stored in the DB. You usually don't need to call this directly;
# by default, tabcat.task.start() will cause it to be called periodically.
#
# The only option is "force". If true, this will abort pending syncs unless
# they were already uploading all the event log items we wanted to.
#
# You must call tabcat.task.start() before calling this (you don't have to
# wait for the promise it returns to resolve).
tabcat.task.syncEventLog = (options) ->
  # require taskDoc
  if not taskDoc?
    throw new Error('no taskDoc; call tabcat.task.start() first')

  # don't upload events if there's already one pending
  if eventSyncXHR?
    # if there's more to upload, abort the current upload and restart
    if options?.force and eventLog.length > eventSyncEndIndex
      # if we're spilling to localStorage, this won't be a real xhr
      if eventSyncXHR.abort?
        eventSyncXHR.abort()
      eventSyncXHR = null
    else
      return eventSyncXHR

  # if no new events to upload, do nothing
  if eventLog.length <= eventSyncStartIndex
    return $.Deferred().resolve()

  # upload everything we haven't so far
  #
  # Store value of eventSyncEndIndex in local scope just in case something
  # weird happens with multiple overlapping callbacks
  endIndex = eventSyncEndIndex = eventLog.length

  # This is only called by tabcat.task.start(), so we can safely assume
  # taskDoc exists and has the fields we want.
  eventLogDoc = {
    _id: tabcat.couch.randomUUID()
    type: 'eventLog'
    taskId: taskDoc._id
    encounterId: taskDoc.encounterId
    patientCode: taskDoc.patientCode
    user: tabcat.user.get()
    startIndex: eventSyncStartIndex
    items: eventLog.slice(eventSyncStartIndex, endIndex)
  }

  eventSyncXHR = tabcat.db.putDoc(DATA_DB, eventLogDoc)

  # track that events were successfully uploaded
  eventSyncXHR.then(-> eventSyncStartIndex = endIndex)

  # track that we're ready for a new XHR
  # (this also implicitly returns eventSyncXHR)
  eventSyncXHR.always(-> eventSyncXHR = null)


# Log an event whenever the viewport changes (scroll/resize). You can also
# access this with the trackViewport option to tabcat.task.start()
#
# If there is a series of viewport changes without other events logged between
# them, we try to only keep the most recent one.
#
# TODO: give a way to turn this on/off in the middle of a task
tabcat.task.trackViewportInEventLog = _.once(->
  isViewportLogItem = (item) ->
    item? and not item.interpretation? and _.isEqual(
      _.keys(item.state), ['viewport'])

  handler = (event) ->
    # if the last event log item is also a viewport event, delete it, assuming
    # we haven't already tried to upload it to the DB
    if (eventLog.length > eventSyncEndIndex and
        isViewportLogItem(_.last(eventLog)))
      eventLog.pop()

    tabcat.task.logEvent(viewport: tabcat.task.getViewportInfo(), event)

  $(window).resize(handler)
  $(window).scroll(handler)
)


# Use this instead of $(document).ready(), so that we can also wait for
# tabcat.task.start() to complete
tabcat.task.ready = (handler) ->
  $.when($.ready.promise(), tabcat.task.start()).then(-> handler())


waitFor = (milliseconds) ->
  deferred = $.Deferred()
  window.setTimeout((-> deferred.resolve()), milliseconds)
  return deferred


# splash a "Task complete!" page for the user, upload task info to the DB, and
#  return to the task selector page.
#
# Note that this will blow away everything in the <body> tag, so grab anything
# you need before calling this method.
#
# options:
# - minWait: minimum number of milliseconds to wait before redirecting to
#   another page
tabcat.task.finish = (options) ->
  now = tabcat.clock.now()

  options ?= {}
  minWait = options.minWait ? 1000
  fadeDuration = options.fadeDuration ? 200

  # start the timer
  waitedForMinWait = tabcat.ui.wait(minWait)

  # splash up Task complete! screen
  $body = $('body')
  $body.empty()
  $body.hide()
  tabcat.ui.linkEmToPercentOfHeight($body)
  $body.attr('class', 'fullscreen unselectable blueBackground taskComplete')
  $messageP = $('<p class="message">Task complete!</p>')
  $body.append($messageP)
  $body.fadeIn(duration: fadeDuration)

  tabcat.encounter.markTaskFinished(tabcat.task.getTaskName())

  # make sure start() has completed!
  tabcat.task.start().then(->
    taskDoc.finishedAt = now
    if options?.interpretation
      taskDoc.interpretation = options.interpretation

    $.when(
      tabcat.db.putDoc(DATA_DB, taskDoc),
      tabcat.task.syncEventLog(force: true),
      waitedForMinWait).then(
      ->
        if tabcat.task.patientHasDevice()
          window.location = '../core/return-to-examiner.html'
        else
          window.location = '../core/tasks.html'
      )
  )


# get basic information about the browser. This should not change
# over the course of the task
# TODO: add screen DPI/physical size, if available
tabcat.task.getBrowserInfo = ->
  screenHeight: screen.height
  screenWidth: screen.width
  userAgent: navigator.userAgent


# Get information about the viewport. If you want to track changes to the
# viewport (scroll/resize) in eventLog, it's recommended you
# use tabcat.task.trackViewportInEventLog() rather than including viewport
# info in other events you log.
tabcat.task.getViewportInfo = ->
  $window = $(window)
  return {
    left: $window.scrollLeft()
    top: $window.scrollTop()
    width: $window.width()
    height: $window.height()
  }


# get the bounding box for the given (non-jQuery-select-wrapped) DOM element,
# with fields "top", "bottom", "left", and "right"
#
# we use getBoundingClientRect() rather than the jQuery alternative to get
# floating-point values
tabcat.task.getElementBounds = (element) ->
  # some browsers include height and width, but it's redundant
  _.pick(element.getBoundingClientRect(), 'top', 'bottom', 'left', 'right')


# Appends an event to the event log, with these fields:
# - state: object representing the state of the world at the time the event
#   happened. Common fields are:
#   - intensity: intensity
#   - practiceMode: are we in practice mode? (don't set at all if false)
#   - stimuli: task-specific info about what's actually shown on the screen.
#     Some stimuli fields so far: "lines", "practiceCaption"
#   - trialNum: which trial we're on (0-indexed, includes practice trials)
# - event: a summary of the event (currently we keep type, pageX, and pageY).
#   You can pass in a jQuery event, or just a string for event type.
# - interpretation: the meaning of the event (i.e. was it the right answer?)
#   Common fields are:
#   - correct (boolean): did the patient select the correct answer
#   - intensityChange: change in intensity (easiness) due to patient's choice
#   - reversal (boolean): was this a reversal?
# - now: if not set, the time of the event relative to start of encounter, or
#   tabcat.clock.now() if "event" is undefined
#
# state, event, and interpretation are not included if null/undefined.
#
# You should aim for readable, compact formats for state and interpretation.
# For most true/false values, only include the field if it's true.
tabcat.task.logEvent = (state, event, interpretation, now) ->
  if not now?  # ...when?
    if event?.timeStamp?
      now = event.timeStamp - tabcat.clock.offset()
    else
      now = tabcat.clock.now()

  eventLogItem = now: now

  if typeof event is 'string'
    eventLogItem.event = {type: event}
  else if event?
    eventLogItem.event = _.pick(event, 'pageX', 'pageY', 'type')

  if interpretation?
    eventLogItem.interpretation = interpretation

  if state?
    eventLogItem.state = state

  eventLog.push(eventLogItem)


# Get a (shallow) copy of the event log
tabcat.task.getEventLog = ->
  eventLog.slice(0)


# Get the ID of the current task, or null if start() hasn't been called
tabcat.task.getTaskId = ->
  taskDoc?._id


# Get the task name from the URL
tabcat.task.getTaskName = ->
  _.last(window.location.pathname.split('/'), 2)[0]


NON_TASK_DESIGN_DOCS = ['core']

# Get the name of all tabcat tasks. This assumes our current URL points
# to a doc in the tabcat DB
tabcat.task.getAllTaskNames = ->
  tabcatBase = window.location.pathname.split('/')[0..1]
  path = tabcatBase.concat('_all_docs').join('/')

  $.getJSON(path).then(
    (response) ->
      (row.key[8..] for row in response.rows \
        when row.key[0..7] is '_design/' and \
          row.key[8..] not in NON_TASK_DESIGN_DOCS)
  )
