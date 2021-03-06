###
Copyright (c) 2014, Regents of the University of California
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  1. Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
###
# Functions only used by the TabCAT console, and only available from
# there. Used to be in TabCAT.UI.

@TabCAT ?= {}
TabCAT.Console = {}

# INITIALIZATION

# default fallback language, for i18n
DEFAULT_FALLBACK_LNG = 'en'

# call this first. Analogous to TabCAT.Task.start()
#
# this sets up i18n, starts sync of spilled docs, and updates
# the status bar (once the page is ready)
TabCAT.Console.start = _.once((options) ->
  # set up i18n
  i18n_options = _.extend(
    {fallbackLng: DEFAULT_FALLBACK_LNG, resStore: {}},
    options?.i18n)
  $.i18n.init(i18n_options)

  # sync spilled docs
  TabCAT.DB.startSpilledDocSync()

  # update status bar
  $(TabCAT.Console.updateStatusBar)
)


# STATUS BAR

# warn when local storage is more than 75% full
# typical tasks use 0.5% of browser storage
LOCAL_STORAGE_WARNING_THRESHOLD = 75

# keep status messages for at least a second
OFFLINE_STATUS_MIN_CHANGE_TIME = 2000

# DB where design docs and task content is stored
TABCAT_DB = 'tabcat'


keepOfflineStatusUntil = null
lastOfflineStatusType = 0

# update the statusBar div, populating it if necessary
#
# this also implicitly unsets patientHasDevice
#
# this is also responsible for swapping in updated versions of the
# application cache (Android browser seems to need this)
TabCAT.Console.updateStatusBar = ->
  TabCAT.Task.patientHasDevice(false)

  $statusBar = $('#statusBar')

  if TabCAT.Console.inSandbox()
    $statusBar.addClass('sandbox')

  # populate with new HTML if we didn't already
  if $statusBar.find('div.left').length is 0
    $statusBar.html(
      """
      <div class="left">
        <span class="banner"></span>
        <span class="version"></span>
        <p class="offline"></p>
      </div>
      <div class="right">
        <p class="email">&nbsp;</p>
        <button class="login" style="display:none"></span>
      </div>
      <div class="center">
        <p class="encounter"></p>
        <p class="clock"></p>
      </div>
      """
    )

    $statusBar.find('.version').text(TabCAT.version)

    $statusBar.find('button.login').on('click', (event) ->
      button = $(event.target)
      if button.text() == 'Log Out'
        $emailP = $statusBar.find('p.email')
        # do something even if logout is slow
        oldContents = $emailP.html()
        $statusBar.find('p.email').text('Logging out...')
        TabCAT.UI.logout()
        # this only happens if user decides not to log out
        $emailP.html(oldContents)
      else
        TabCAT.UI.requestLogin()
    )

  $emailP = $statusBar.find('p.email')
  $button =  $statusBar.find('button.login')
  $encounterP = $statusBar.find('p.encounter')

  user = TabCAT.User.get()

  if user?
    $emailP.text(user)
    $button.text('Log Out')
  else
    $emailP.text('not logged in')
    $button.text('Log In')

  $button.show()

  # only check offline status occasionally
  updateOfflineStatus()
  TabCAT.Console.updateStatusBar.offlineInterval = window.setInterval(
    updateOfflineStatus, 500)

  # don't show encounter info unless patient is logged in
  patientCode = TabCAT.Encounter.getPatientCode()
  if patientCode? and user?
    encounterNum = TabCAT.Encounter.getNum()
    encounterNumText = if encounterNum? then ' #' + encounterNum else ''

    $encounterP.text(
      'Encounter' + encounterNumText + ' with Patient ' + patientCode)

    if not TabCAT.Console.updateStatusBar.clockInterval?
      TabCAT.Console.updateStatusBar.clockInterval = window.setInterval(
        updateEncounterClock, 50)
  else
    $encounterP.empty()
    if TabCAT.Console.updateStatusBar.clockInterval?
      window.clearInterval(TabCAT.Console.updateStatusBar.clockInterval)
    $statusBar.find('p.clock').empty()


# update the encounter clock on the statusBar
updateEncounterClock = ->
  # handle end of encounter gracefully
  if TabCAT.Encounter.isOpen()
    now = TabCAT.Clock.now()

    seconds = Math.floor(now / 1000) % 60
    if seconds < 10
      seconds = '0' + seconds
    minutes = Math.floor(now / 60000) % 60
    if minutes < 10
      minutes = '0' + minutes
    hours = Math.floor(now / 3600000)
    time = hours + ':' + minutes + ':' + seconds

    $('#statusBar p.clock').text(time)
  else
    $('#statusBar p.clock').empty()


# update the offline status on the statusBar, while attempting not
# to flicker status messages so quickly that we can't read them
updateOfflineStatus = ->
  now = $.now()
  [statusType, statusHtml] = offlineStatusTypeAndHtml()

  if (keepOfflineStatusUntil? and now < keepOfflineStatusUntil \
      and statusType isnt lastOfflineStatusType)
    return

  # don't bother holding blank message for a second
  if statusHtml
    lastOfflineStatusType = statusType
    keepOfflineStatusUntil = now + OFFLINE_STATUS_MIN_CHANGE_TIME

  $('#statusBar').find('p.offline').html(statusHtml)


# return the type of offline status and html to display.
#
# This also swaps in an updated application cache, if necessary
offlineStatusTypeAndHtml = ->
  now = $.now()

  appcache = window.applicationCache

  # if there's an updated version of the cache ready, swap it in
  if appcache.status is appcache.UPDATEREADY
    appcache.swapCache()

  if navigator.onLine is false
    if (appcache.status is appcache.UNCACHED or \
        appcache.status >= appcache.OBSOLETE)
      return [1, '<span class="warning">PLEASE CONNECT TO NETWORK</span>']
    else
      percentFullHtml = offlineStatusStoragePercentFullHtml()
      if percentFullHtml
        return [2, 'OFFLINE MODE (storage ' + percentFullHtml + ')']
      else
        return [2, 'OFFLINE MODE']

  if appcache.status is appcache.DOWNLOADING
    return [3, 'loading content for offline mode']

  if (appcache.status is appcache.UNCACHED or \
      appcache.status >= appcache.OBSOLETE)
    return [4, '<span class="warning">offline mode unavailable</span>']

  # not exactly offline, but can't sync (maybe wrong network?)
  percentFullHtml = offlineStatusStoragePercentFullHtml()
  if percentFullHtml
    return [5, 'offline storage ' + percentFullHtml]

  return [0, '']


# helper for offlineStatusHtml(). returns "#.#% full" plus markup
offlineStatusStoragePercentFullHtml = ->
  if not TabCAT.DB.spilledDocsRemain()
    return ''

  percentFull = TabCAT.DB.percentOfLocalStorageUsed()
  percentFullHtml = Math.min(percentFull, 100).toFixed(1) + '% full'
  if percentFull >= LOCAL_STORAGE_WARNING_THRESHOLD
    percentFullHtml = '<span class="warning">' + percentFullHtml + '</span>'

  return percentFullHtml


TabCAT.Console.DEFAULT_TASK_ICON_URL = (
  "/#{TABCAT_DB}/_design/console/img/icon.png")

# extract icon URL from task info (from TabCAT.Task.getTaskInfo())
TabCAT.Console.getTaskIconUrl = (task) ->
  if task.designDocId? and task.icon?
    "/#{TABCAT_DB}/#{task.designDocId}/#{task.icon}"
  else
    DEFAULT_TASK_ICON_URL

# extract start URL from task info (from TabCAT.Task.getTaskInfo())
TabCAT.Console.getTaskStartUrl = (task) ->
  if task.designDocId? and task.start?
    "/#{TABCAT_DB}/#{task.designDocId}/#{task.start}"


# used by inSandbox()
SANDBOX_REGEX = \
  /(sandbox|^\d+\.\d+\.\d+\.\d+$)/i


# Infer from the hostname whether we're in sandbox mode. This happens if it
# contains "sandbox" or is an IP address.
#
# Sandbox mode is meant to only affect the UI: different warning messages,
# pre-filled form inputs, etc.
#
# We intentially don't do anything for the hostname "localhost"
# so that it's easy to test non-sandbox mode (use "127.0.0.1" instead).
#
# You can optionally pass in a hostname (by default we use
# window.location.hostname).
TabCAT.Console.inSandbox = (hostname) ->
  SANDBOX_REGEX.test(hostname ? window.location.hostname)

# constants for sandbox mode
TabCAT.Console.sandboxIcon = 'img/sandbox/icon.png'
TabCAT.Console.sandboxPassword = 's@ndbox'
TabCAT.Console.sandboxTitle = 'TabCAT Sandbox'
TabCAT.Console.sandboxUser = 's@ndbox'


# displaying scores

SCORE_HTML = '''
<div class="score">
  <div class="scoreHeader">
    <span class="description"></span>
  </div>
  <div class="scoreBody">
    <div class="rawScore">
      <p class="description">Raw Score</p>
      <p class="value"></p>
    </div>
    <div class="norms">
      <table class="norm">
        <thead>
          <tr>
            <th class="age">Age</th>
            <th class="mean">Mean</th>
            <th class="stddev">Std. Dev.</th>
            <th class="percentile">Percentile</th>
          </tr>
        </thead>
        <tbody>
        </tbody>
      </table>
    </div>
  </div>
</div>
'''

NORM_HTML = '''
<tr>
  <td class="age"></td>
  <td class="mean"></td>
  <td class="stddev"></td>
  <td class="percentile"></td>
</tr>
'''

TabCAT.Console.populateWithScores = ($scoresDiv, scores) ->
  $scoresDiv.empty()

  for score in scores
    $score = $(SCORE_HTML)
    $score.find('.scoreHeader .description').text(
      score.description)
    $score.find('.scoreBody .rawScore .value').text(
      score.value.toFixed(1))

    if score.norms?
      for norm in score.norms
        $norm = $(NORM_HTML)

        minAge = norm.cohort?.minAge ? 0
        if norm.cohort?.maxAge?
          age = minAge + '-' + norm.cohort.maxAge
        else
          age = minAge + '+'
        $norm.find('.age').text(age)

        $norm.find('.mean').text(norm.mean ? '-')
        $norm.find('.stddev').text(norm.stddev ? '-')

        percentile = norm.percentile

        # infer percentile
        if (not percentile?) and norm.mean? and norm.stddev
          g = gaussian(norm.mean, norm.stddev * norm.stddev)
          percentile = 100 * g.cdf(score.value)
          if score.lessIsMore
            percentile = 100 - percentile

        if percentile?
          percentile = Math.floor(percentile) + '%'

        $norm.find('.percentile').text(percentile ? '-')

        $score.find('.scoreBody .norms tbody').append($norm)

    $scoresDiv.append($score)
