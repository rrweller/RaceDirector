angular.module('beamng.apps').directive('raceDirector', ['$interval', function ($interval) {
  var APP_STYLESHEET_ID = 'raceDirectorBarStylesheet'
  var APP_STYLESHEET_PATH = '/ui/modules/apps/RaceDirector/app.css'
  var APP_REFRESH_INTERVAL_MS = 350
  var UI_CONFIG_STORAGE_KEY = 'apps:raceDirector.uiConfig'
  var UI_CONFIG_EVENT_NAME = 'raceDirectorUiConfigChanged'
  var CONFIG_WINDOW_EVENT_NAME = 'raceDirectorConfigWindowChanged'
  var CONFIG_WINDOW_STORAGE_KEY = 'apps:raceDirector.configWindowOpen'

  return {
    templateUrl: '/ui/modules/apps/RaceDirector/app.html',
    replace: false,
    restrict: 'E',
    scope: false,
    link: function (scope) {
      var ctrl = scope.raceDirector
      refreshAppStylesheet()
      ctrl.initialLoad()

      var pollPromise = $interval(function () {
        ctrl.refresh()
      }, APP_REFRESH_INTERVAL_MS)

      scope.$on('$destroy', function () {
        $interval.cancel(pollPromise)
        bngApi.engineLua('if extensions.raceDirector and extensions.raceDirector.onUiClosed then extensions.raceDirector.onUiClosed() end')
      })

      scope.$on('VehicleFocusChanged', function () {
        ctrl.refresh()
      })

      scope.$on('VehicleReset', function () {
        ctrl.refresh()
      })

      scope.$on('ScenarioRestarted', function () {
        ctrl.refresh()
      })
    },
    controller: ['$scope', function ($scope) {
      var vm = this
      vm.loading = false
      vm.ui = {
        configWindowOpen: false
      }
      vm.settings = {
        uiScale: 1
      }
      vm.state = buildDefaultState()

      vm.initialLoad = function () {
        applyUiConfig(readLocalUiConfig())
        vm.ui.configWindowOpen = isConfigWindowOpen()
        registerWindowListeners()
        restoreConfigWindowIfNeeded()
        bngApi.engineLua('extensions.load("raceDirector")')
        vm.refresh()
      }

      vm.refresh = function () {
        if (vm.loading) {
          return
        }

        vm.loading = true
        bngApi.engineLua(
          '(function() if not extensions.raceDirector then extensions.load("raceDirector") end return extensions.raceDirector and extensions.raceDirector.getState and extensions.raceDirector.getState() or {} end)()',
          function (payload) {
            finishRefresh(function () {
              applyState(payload || {})
              vm.ui.configWindowOpen = isConfigWindowOpen()
            })
          }
        )
      }

      vm.openConfigWindow = function () {
        writeConfigWindowPreference(true)
        vm.ui.configWindowOpen = true
        $scope.$emit('appContainer:ensureAppVisible', JSON.stringify({ appName: 'RaceDirectorConfig' }))
        resetLayoutDirtyFlag()
        notifyWindowStateChanged()
      }

      vm.togglePlayback = function () {
        invokeAction('extensions.raceDirector.setPlaying(' + (vm.state.runtime.playing ? 'false' : 'true') + ')')
      }

      vm.previousShot = function () {
        invokeAction('extensions.raceDirector.skipShot(-1)')
      }

      vm.nextShot = function () {
        invokeAction('extensions.raceDirector.skipShot(1)')
      }

      vm.entryCount = function () {
        return ((vm.state.config && vm.state.config.entries) || []).length
      }

      vm.runtimeToneClass = function () {
        var runtime = vm.state.runtime || {}
        if (runtime.playing) {
          return 'is-live'
        }
        if (runtime.activeEntryId) {
          return 'is-paused'
        }
        return 'is-idle'
      }

      vm.activeShotLabel = function () {
        var runtime = vm.state.runtime || {}
        if (runtime.activeEntryName) {
          return runtime.activeEntryName
        }
        if (vm.entryCount() > 0) {
          return 'Ready to start'
        }
        return 'No shots saved'
      }

      vm.currentShotModeLabel = function () {
        var runtime = vm.state.runtime || {}
        if (runtime.activeEntryType === 'trackside') {
          return 'Trackside'
        }
        if (runtime.activeEntryType === 'onboard') {
          return 'Onboard'
        }
        if (vm.entryCount() > 0) {
          return 'Standby'
        }
        return 'Setup'
      }

      vm.scaleStyle = function () {
        var scale = normalizeUiScale(vm.settings.uiScale)
        var style = {
          transform: 'scale(' + scale + ')'
        }

        if (scale > 1) {
          style.width = (100 / scale).toFixed(3) + '%'
          style.height = (100 / scale).toFixed(3) + '%'
        } else {
          style.width = '100%'
          style.height = '100%'
        }

        return style
      }

      function invokeAction(expression) {
        vm.loading = true
        bngApi.engineLua(
          '(function() if not extensions.raceDirector then extensions.load("raceDirector") end return ' + expression + ' end)()',
          function (payload) {
            finishRefresh(function () {
              applyState(payload || {})
              vm.ui.configWindowOpen = isConfigWindowOpen()
            })
          }
        )
      }

      function applyState(payload) {
        vm.state = {
          config: payload.config || buildDefaultConfig(),
          runtime: payload.runtime || buildDefaultRuntime()
        }
      }

      function buildDefaultState() {
        return {
          config: buildDefaultConfig(),
          runtime: buildDefaultRuntime()
        }
      }

      function buildDefaultConfig() {
        return {
          entries: []
        }
      }

      function buildDefaultRuntime() {
        return {
          playing: false,
          stateLabel: 'Idle',
          activeEntryId: '',
          activeEntryName: '',
          activeEntryType: ''
        }
      }

      function finishRefresh(applyStateCallback) {
        $scope.$evalAsync(function () {
          applyStateCallback()
          vm.loading = false
        })
      }

      function registerWindowListeners() {
        if (typeof window === 'undefined' || !window.addEventListener) {
          return
        }

        window.addEventListener(UI_CONFIG_EVENT_NAME, onUiConfigChanged)
        window.addEventListener(CONFIG_WINDOW_EVENT_NAME, onConfigWindowChanged)

        $scope.$on('$destroy', function () {
          window.removeEventListener(UI_CONFIG_EVENT_NAME, onUiConfigChanged)
          window.removeEventListener(CONFIG_WINDOW_EVENT_NAME, onConfigWindowChanged)
        })
      }

      function onUiConfigChanged() {
        $scope.$evalAsync(function () {
          applyUiConfig(readLocalUiConfig())
        })
      }

      function onConfigWindowChanged() {
        $scope.$evalAsync(function () {
          vm.ui.configWindowOpen = isConfigWindowOpen()
        })
      }

      function applyUiConfig(config) {
        if (!config || typeof config !== 'object') {
          return
        }

        vm.settings.uiScale = normalizeUiScale(config.uiScale)
      }

      function readLocalUiConfig() {
        try {
          var rawValue = localStorage.getItem(UI_CONFIG_STORAGE_KEY)
          if (!rawValue) {
            return null
          }

          return JSON.parse(rawValue)
        } catch (error) {
          return null
        }
      }

      function isConfigWindowOpen() {
        var apps = window && window.UIAppStorage && window.UIAppStorage.current && window.UIAppStorage.current.apps
        var index
        var app
        if (!apps || !angular.isArray(apps)) {
          return false
        }

        for (index = 0; index < apps.length; index++) {
          app = apps[index]
          if (app && app.appName === 'RaceDirectorConfig') {
            return true
          }
        }

        return false
      }

      function notifyWindowStateChanged() {
        if (typeof window === 'undefined' || !window.dispatchEvent || typeof Event !== 'function') {
          return
        }

        window.dispatchEvent(new Event(CONFIG_WINDOW_EVENT_NAME))
      }

      function restoreConfigWindowIfNeeded() {
        if (!readConfigWindowPreference()) {
          return
        }

        if (isConfigWindowOpen()) {
          vm.ui.configWindowOpen = true
          return
        }

        if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
          window.requestAnimationFrame(function () {
            $scope.$evalAsync(function () {
              vm.openConfigWindow()
            })
          })
          return
        }

        $scope.$evalAsync(function () {
          vm.openConfigWindow()
        })
      }

      function resetLayoutDirtyFlag() {
        if (typeof window === 'undefined' || !window.UIAppStorage) {
          return
        }

        window.UIAppStorage.layoutDirty = false
      }

      function normalizeUiScale(scale) {
        var numericScale = Number(scale)
        if (!isFinite(numericScale) || numericScale <= 0) {
          return 1
        }

        return numericScale
      }

      function readConfigWindowPreference() {
        try {
          return localStorage.getItem(CONFIG_WINDOW_STORAGE_KEY) === 'true'
        } catch (error) {
          return false
        }
      }

      function writeConfigWindowPreference(isOpen) {
        try {
          localStorage.setItem(CONFIG_WINDOW_STORAGE_KEY, isOpen ? 'true' : 'false')
        } catch (error) {
          return null
        }

        return true
      }
    }],
    controllerAs: 'raceDirector'
  }

  function refreshAppStylesheet() {
    if (typeof document === 'undefined') {
      return
    }

    var head = document.head || document.getElementsByTagName('head')[0]
    var link
    if (!head) {
      return
    }

    link = document.getElementById(APP_STYLESHEET_ID)
    if (!link) {
      link = document.createElement('link')
      link.id = APP_STYLESHEET_ID
      link.rel = 'stylesheet'
      link.type = 'text/css'
      head.appendChild(link)
    }

    link.href = APP_STYLESHEET_PATH + '?v=' + Date.now()
  }
}])
