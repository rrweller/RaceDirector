angular.module('beamng.apps').directive('raceDirectorConfig', ['$interval', function ($interval) {
  var APP_STYLESHEET_ID = 'raceDirectorConfigStylesheet'
  var APP_STYLESHEET_PATH = '/ui/modules/apps/RaceDirectorConfig/app.css'
  var APP_REFRESH_INTERVAL_MS = 350
  var UI_CONFIG_STORAGE_KEY = 'apps:raceDirector.uiConfig'
  var UI_CONFIG_EVENT_NAME = 'raceDirectorUiConfigChanged'
  var CONFIG_WINDOW_EVENT_NAME = 'raceDirectorConfigWindowChanged'
  var CONFIG_WINDOW_STORAGE_KEY = 'apps:raceDirector.configWindowOpen'
  var WINDOW_FRAME_STORAGE_KEY = 'apps:raceDirector.configWindowFrame'
  var SHOT_COLLAPSE_STORAGE_KEY = 'apps:raceDirector.entryCollapseState'
  var MIN_WINDOW_WIDTH = 680
  var MIN_WINDOW_HEIGHT = 520
  var WINDOW_SNAP_PX = 6
  var UI_SCALE_OPTIONS = [
    { label: '50%', value: 0.5 },
    { label: '66%', value: 2 / 3 },
    { label: '75%', value: 0.75 },
    { label: '100%', value: 1 },
    { label: '125%', value: 1.25 },
    { label: '150%', value: 1.5 }
  ]

  return {
    templateUrl: '/ui/modules/apps/RaceDirectorConfig/app.html',
    replace: false,
    restrict: 'E',
    scope: false,
    link: function (scope, element) {
      var ctrl = scope.raceDirectorConfig
      refreshAppStylesheet()
      ctrl.bindHostElement(element && element[0])
      ctrl.initialLoad()

      var pollPromise = $interval(function () {
        ctrl.refresh()
      }, APP_REFRESH_INTERVAL_MS)

      scope.$on('$destroy', function () {
        $interval.cancel(pollPromise)
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
    controller: ['$scope', '$document', 'UIAppStorage', 'UiAppsService', function ($scope, $document, UIAppStorage, UiAppsService) {
      var vm = this
      vm.loading = false
      vm.rootNode = null
      vm.hostNode = null
      vm.containerNode = null
      vm.dragSession = null
      vm.resizeSession = null
      vm.frameApplyHandle = null
      vm.ui = {
        tab: 'overview',
        scaleInput: '100',
        collapsedEntries: {},
        fieldDrafts: {},
        invalidFields: {},
        fieldLocks: {},
        activeFieldKey: ''
      }
      vm.settings = {
        uiScale: 1
      }
      vm.state = buildDefaultState()

      vm.bindHostElement = function (rootNode) {
        vm.rootNode = rootNode || null
        vm.hostNode = null
        vm.containerNode = null
        scheduleFrameApply()
      }

      vm.initialLoad = function () {
        applyUiConfig(readLocalUiConfig())
        applyCollapsedEntryState(readCollapsedEntryState())
        writeConfigWindowPreference(true)
        registerWindowListeners()
        notifyWindowStateChanged()
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
            })
          }
        )
      }

      vm.closeWindow = function () {
        cancelWindowInteraction()
        writeConfigWindowPreference(false)
        $scope.$emit('appContainer:removeApp', 'RaceDirectorConfig')
        resetLayoutDirtyFlag()
        notifyWindowStateChanged()
      }

      vm.setTab = function (tab) {
        vm.ui.tab = tab
      }

      vm.captureTracksideCamera = function () {
        vm.ui.tab = 'shots'
        invokeAction('extensions.raceDirector.captureTracksideCamera()')
      }

      vm.replaceTrackside = function (entry) {
        if (!entry || !entry.id) {
          return
        }

        invokeAction('extensions.raceDirector.overwriteTracksideCamera(' + bngApi.serializeToLua(entry.id) + ')')
      }

      vm.addOnboardEntry = function () {
        vm.ui.tab = 'shots'
        invokeAction('extensions.raceDirector.addOnboardEntry()')
      }

      vm.previewEntry = function (entry) {
        if (!entry || !entry.id) {
          return
        }

        invokeAction('extensions.raceDirector.previewEntry(' + bngApi.serializeToLua(entry.id) + ')')
      }

      vm.deleteEntry = function (entry) {
        if (!entry || !entry.id) {
          return
        }

        invokeAction('extensions.raceDirector.deleteEntry(' + bngApi.serializeToLua(entry.id) + ')')
      }

      vm.moveEntry = function (entry, offset) {
        if (!entry || !entry.id || !offset) {
          return
        }

        invokeAction(
          'extensions.raceDirector.moveEntry(' +
            bngApi.serializeToLua(entry.id) + ', ' +
            bngApi.serializeToLua(offset) + ')'
        )
      }

      vm.persistConfig = function () {
        if (!vm.state.config) {
          return
        }

        invokeAction('extensions.raceDirector.saveConfig(' + bngApi.serializeToLua(vm.state.config) + ')')
      }

      vm.setEntryValue = function (entry, key, value) {
        if (!entry || !key) {
          return
        }

        entry[key] = value
        if (key === 'targetMode' && value === 'randomCar') {
          entry.targetValue = 1
        }

        vm.persistConfig()
      }

      vm.onEntryOptionKeydown = function ($event, entry, key, options, valueKey) {
        var values
        var currentIndex
        var nextIndex
        var step
        if (!$event || !entry || !key) {
          return
        }

        if ($event.key !== 'ArrowLeft' &&
            $event.key !== 'ArrowRight' &&
            $event.key !== 'ArrowUp' &&
            $event.key !== 'ArrowDown') {
          return
        }

        values = normalizeOptionValues(options, valueKey)
        if (!values.length) {
          return
        }

        currentIndex = values.indexOf(entry[key])
        if (currentIndex === -1) {
          currentIndex = 0
        }

        step = ($event.key === 'ArrowLeft' || $event.key === 'ArrowUp') ? -1 : 1
        nextIndex = (currentIndex + step + values.length) % values.length
        vm.setEntryValue(entry, key, values[nextIndex])

        if (typeof $event.preventDefault === 'function') {
          $event.preventDefault()
        }
        if (typeof $event.stopPropagation === 'function') {
          $event.stopPropagation()
        }
      }

      vm.showTargetValueField = function (entry) {
        return !!(entry && entry.type === 'onboard' && entry.targetMode !== 'randomCar')
      }

      vm.isEntryCollapsed = function (entry) {
        return !!(entry && entry.id && vm.ui.collapsedEntries[entry.id])
      }

      vm.toggleEntryCollapsed = function (entry) {
        if (!entry || !entry.id) {
          return
        }

        vm.ui.collapsedEntries[entry.id] = !vm.ui.collapsedEntries[entry.id]
        persistCollapsedEntryState()
      }

      vm.entryCount = function () {
        return (vm.state.config.entries || []).length
      }

      vm.tracksideCount = function () {
        return countEntriesOfType('trackside')
      }

      vm.onboardCount = function () {
        return countEntriesOfType('onboard')
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

      vm.nextShotLabel = function () {
        var runtime = vm.state.runtime || {}
        if (runtime.nextEntryName) {
          return runtime.nextEntryName
        }
        if (!vm.loopSequenceEnabled() && runtime.activeEntryIndex && !runtime.nextEntryId) {
          return 'End of sequence'
        }
        if (vm.entryCount() > 0) {
          return 'Waiting'
        }
        return 'No sequence'
      }

      vm.referenceLabel = function () {
        var runtime = vm.state.runtime || {}
        if (!runtime.referenceVehName) {
          return 'Waiting'
        }
        return runtime.referenceVehName
      }

      vm.loopSequenceEnabled = function () {
        var settings = vm.state && vm.state.config ? vm.state.config.settings : null
        return !settings || settings.loopSequence !== false
      }

      vm.describeTarget = function (entry) {
        if (!entry) {
          return ''
        }

        if (entry.targetMode === 'randomCar') {
          return 'Random active car'
        }

        if (entry.targetMode === 'specificCar') {
          return 'Specific vehicle ID ' + (entry.targetValue || 1)
        }

        return 'Race position ' + (entry.targetValue || 1)
      }

      vm.onboardAngleLabel = function (value) {
        return lookupOptionLabel(
          vm.state && vm.state.options ? vm.state.options.onboardAngles : [],
          value,
          formatOnboardAngleLabel(value)
        )
      }

      vm.entrySummary = function (entry) {
        if (!entry) {
          return ''
        }

        if (entry.type === 'trackside') {
          return 'Holds this saved camera while cars remain inside its view and range.'
        }

        return 'Switches into BeamNG\'s ' + vm.onboardAngleLabel(entry.onboardAngle) + ' camera for a selected race target.'
      }

      vm.entryMetaLine = function (entry) {
        if (!entry) {
          return ''
        }

        if (entry.type === 'trackside') {
          return 'Range ' + (entry.triggerDistance || 0) + 'm | Min ' + (entry.minHoldMs || 0) + 'ms'
        }

        return vm.onboardAngleLabel(entry.onboardAngle) + ' | Min ' + (entry.minHoldMs || 0) + 'ms | ' + vm.describeTarget(entry)
      }

      vm.sequenceHint = function (entry) {
        if (!entry) {
          return ''
        }

        if (entry.type === 'trackside') {
          return 'Trackside | range ' + (entry.triggerDistance || 0) + 'm | min ' + (entry.minHoldMs || 0) + 'ms'
        }

        return 'Onboard | ' + vm.onboardAngleLabel(entry.onboardAngle) + ' | ' + vm.describeTarget(entry) + ' | min ' + (entry.minHoldMs || 0) + 'ms'
      }

      vm.formatVector = function (vector) {
        if (!vector || vector.x === undefined) {
          return '--'
        }

        return [
          formatNumber(vector.x),
          formatNumber(vector.y),
          formatNumber(vector.z)
        ].join(', ')
      }

      vm.formatFov = function (value) {
        var numericValue = Number(value)
        if (!isFinite(numericValue)) {
          return '--'
        }

        return Math.round(numericValue)
      }

      vm.incrementScale = function () {
        var currentIndex = getUiScaleIndex(vm.settings.uiScale)
        vm.settings.uiScale = UI_SCALE_OPTIONS[Math.min(currentIndex + 1, UI_SCALE_OPTIONS.length - 1)].value
        persistUiConfig()
      }

      vm.decrementScale = function () {
        var currentIndex = getUiScaleIndex(vm.settings.uiScale)
        vm.settings.uiScale = UI_SCALE_OPTIONS[Math.max(currentIndex - 1, 0)].value
        persistUiConfig()
      }

      vm.onScaleInputKeydown = function ($event) {
        if (!$event || $event.key !== 'Enter') {
          return
        }

        vm.applyScaleInput()
        if (typeof $event.preventDefault === 'function') {
          $event.preventDefault()
        }
      }

      vm.applyScaleInput = function () {
        vm.settings.uiScale = parseUiScaleInput(vm.ui.scaleInput, vm.settings.uiScale)
        vm.ui.scaleInput = formatUiScaleInput(vm.settings.uiScale)
        persistUiConfig()
      }

      vm.scaleLabel = function () {
        return formatUiScaleInput(vm.settings.uiScale) + '%'
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

      vm.entryFieldKey = function (entry, key) {
        if (!entry || !entry.id || !key) {
          return ''
        }

        return 'entry:' + entry.id + ':' + key
      }

      vm.configFieldKey = function (key) {
        if (!key) {
          return ''
        }

        return 'config:' + key
      }

      vm.beginFieldEdit = function (fieldKey) {
        if (!fieldKey) {
          return
        }

        if (vm.ui.fieldDrafts[fieldKey] === undefined) {
          vm.ui.fieldDrafts[fieldKey] = normalizeFieldDraftValue(resolveFieldValueFromState(fieldKey))
        }
        vm.ui.activeFieldKey = fieldKey
        vm.ui.fieldLocks[fieldKey] = true
      }

      vm.onFieldInput = function (fieldKey) {
        if (!fieldKey) {
          return
        }

        vm.ui.fieldLocks[fieldKey] = true
        delete vm.ui.invalidFields[fieldKey]
      }

      vm.isFieldInvalid = function (fieldKey) {
        return !!(fieldKey && vm.ui.invalidFields[fieldKey])
      }

      vm.commitConfigTextField = function (key, options) {
        var fieldKey = vm.configFieldKey(key)
        var target = vm.state && vm.state.config ? vm.state.config : null
        commitTextField(fieldKey, target, key, options)
      }

      vm.commitEntryTextField = function (entry, key, options) {
        commitTextField(vm.entryFieldKey(entry, key), entry, key, options)
      }

      vm.commitEntryNumberField = function (entry, key, options) {
        commitNumberField(vm.entryFieldKey(entry, key), entry, key, options)
      }

      vm.onFieldKeydown = function ($event, fieldType, target, key, options) {
        if (!$event || !$event.key) {
          return
        }

        if ($event.key === 'Enter') {
          commitFieldByType(fieldType, target, key, options)
          if ($event.target && typeof $event.target.blur === 'function') {
            $event.target.blur()
          }
          if (typeof $event.preventDefault === 'function') {
            $event.preventDefault()
          }
          return
        }

        if ($event.key === 'Escape') {
          revertFieldByType(fieldType, target, key)
          if ($event.target && typeof $event.target.blur === 'function') {
            $event.target.blur()
          }
          if (typeof $event.preventDefault === 'function') {
            $event.preventDefault()
          }
        }
      }

      vm.startDrag = function ($event) {
        var sourceEvent
        var containerRect
        if (!beginWindowInteraction($event, 'move') || !ensureHostNode()) {
          return
        }

        sourceEvent = getMouseEvent($event)
        containerRect = vm.containerNode.getBoundingClientRect()
        UiAppsService.resetPositionAttributes(vm.hostNode)

        vm.dragSession = {
          containerRect: containerRect,
          startX: (sourceEvent.pageX - containerRect.x) - vm.hostNode.offsetLeft,
          startY: (sourceEvent.pageY - containerRect.y) - vm.hostNode.offsetTop,
          maxLeft: Math.max(0, containerRect.width - vm.hostNode.offsetWidth),
          maxTop: Math.max(0, containerRect.height - vm.hostNode.offsetHeight)
        }
      }

      vm.startResize = function ($event) {
        var sourceEvent
        var containerRect
        if (!beginWindowInteraction($event, 'nwse-resize') || !ensureHostNode()) {
          return
        }

        sourceEvent = getMouseEvent($event)
        containerRect = vm.containerNode.getBoundingClientRect()
        UiAppsService.resetPositionAttributes(vm.hostNode)

        vm.resizeSession = {
          containerRect: containerRect,
          startX: vm.hostNode.offsetLeft,
          startY: vm.hostNode.offsetTop,
          maxWidth: Math.max(MIN_WINDOW_WIDTH, vm.containerNode.clientWidth - vm.hostNode.offsetLeft),
          maxHeight: Math.max(MIN_WINDOW_HEIGHT, vm.containerNode.clientHeight - vm.hostNode.offsetTop),
          pointerX: sourceEvent.pageX,
          pointerY: sourceEvent.pageY
        }
      }

      function countEntriesOfType(type) {
        var entries = (vm.state.config && vm.state.config.entries) || []
        var total = 0

        angular.forEach(entries, function (entry) {
          if (entry && entry.type === type) {
            total = total + 1
          }
        })

        return total
      }

      function commitFieldByType(fieldType, target, key, options) {
        if (fieldType === 'configText') {
          vm.commitConfigTextField(key, options)
          return
        }

        if (fieldType === 'entryText') {
          vm.commitEntryTextField(target, key, options)
          return
        }

        if (fieldType === 'entryNumber') {
          vm.commitEntryNumberField(target, key, options)
        }
      }

      function revertFieldByType(fieldType, target, key) {
        if (fieldType === 'configText') {
          revertFieldDraft(vm.configFieldKey(key), vm.state && vm.state.config ? vm.state.config[key] : '')
          return
        }

        if (fieldType === 'entryText' || fieldType === 'entryNumber') {
          revertFieldDraft(vm.entryFieldKey(target, key), target && key ? target[key] : '')
        }
      }

      function syncAllFieldDrafts() {
        var validKeys = {}
        var config = vm.state && vm.state.config ? vm.state.config : {}
        var entries = config.entries || []

        syncTrackedField(validKeys, vm.configFieldKey('presetName'), config.presetName)

        angular.forEach(entries, function (entry) {
          if (!entry || !entry.id) {
            return
          }

          syncTrackedField(validKeys, vm.entryFieldKey(entry, 'name'), entry.name)
          syncTrackedField(validKeys, vm.entryFieldKey(entry, 'minHoldMs'), entry.minHoldMs)

          if (entry.type === 'trackside') {
            syncTrackedField(validKeys, vm.entryFieldKey(entry, 'triggerDistance'), entry.triggerDistance)
          }

          if (entry.type === 'onboard' && vm.showTargetValueField(entry)) {
            syncTrackedField(validKeys, vm.entryFieldKey(entry, 'targetValue'), entry.targetValue)
          }
        })

        pruneStaleFieldState(validKeys)
      }

      function syncTrackedField(validKeys, fieldKey, value) {
        if (!fieldKey) {
          return
        }

        validKeys[fieldKey] = true
        if (vm.ui.fieldLocks[fieldKey] || vm.ui.invalidFields[fieldKey]) {
          return
        }

        vm.ui.fieldDrafts[fieldKey] = normalizeFieldDraftValue(value)
        delete vm.ui.invalidFields[fieldKey]
      }

      function pruneStaleFieldState(validKeys) {
        angular.forEach(vm.ui.fieldDrafts, function (_value, fieldKey) {
          if (!validKeys[fieldKey]) {
            delete vm.ui.fieldDrafts[fieldKey]
          }
        })

        angular.forEach(vm.ui.invalidFields, function (_value, fieldKey) {
          if (!validKeys[fieldKey]) {
            delete vm.ui.invalidFields[fieldKey]
          }
        })

        angular.forEach(vm.ui.fieldLocks, function (_value, fieldKey) {
          if (!validKeys[fieldKey]) {
            delete vm.ui.fieldLocks[fieldKey]
          }
        })

        if (vm.ui.activeFieldKey && !validKeys[vm.ui.activeFieldKey]) {
          vm.ui.activeFieldKey = ''
        }
      }

      function normalizeFieldDraftValue(value) {
        if (value == null) {
          return ''
        }

        return String(value)
      }

      function resolveValidationOption(option, target, key) {
        if (typeof option === 'function') {
          return option(target, key)
        }

        return option
      }

      function resolveFieldValueFromState(fieldKey) {
        var segments
        var entryId
        var entryKey
        var entries
        var index
        var entry
        if (!fieldKey || typeof fieldKey !== 'string') {
          return ''
        }

        if (fieldKey.indexOf('config:') === 0) {
          return vm.state && vm.state.config ? vm.state.config[fieldKey.slice(7)] : ''
        }

        if (fieldKey.indexOf('entry:') === 0) {
          segments = fieldKey.split(':')
          if (segments.length < 3) {
            return ''
          }
          entryId = segments[1]
          entryKey = segments.slice(2).join(':')
          entries = vm.state && vm.state.config && vm.state.config.entries ? vm.state.config.entries : []
          for (index = 0; index < entries.length; index++) {
            entry = entries[index]
            if (entry && entry.id === entryId) {
              return entry[entryKey]
            }
          }
        }

        return ''
      }

      function markFieldInvalid(fieldKey) {
        if (!fieldKey) {
          return
        }

        vm.ui.invalidFields[fieldKey] = true
        delete vm.ui.fieldLocks[fieldKey]
        if (vm.ui.activeFieldKey === fieldKey) {
          vm.ui.activeFieldKey = ''
        }
      }

      function commitTextField(fieldKey, target, key, options) {
        var draftValue
        var nextValue
        var required
        var maxLength

        if (!fieldKey || !target || !key) {
          return
        }

        draftValue = normalizeFieldDraftValue(vm.ui.fieldDrafts[fieldKey])
        nextValue = draftValue.trim()
        required = !options || options.required !== false
        maxLength = resolveValidationOption(options && options.maxLength, target, key)

        if ((required && !nextValue) || (maxLength && nextValue.length > maxLength)) {
          markFieldInvalid(fieldKey)
          return
        }

        target[key] = nextValue
        delete vm.ui.invalidFields[fieldKey]
        delete vm.ui.fieldLocks[fieldKey]
        if (vm.ui.activeFieldKey === fieldKey) {
          vm.ui.activeFieldKey = ''
        }
        vm.ui.fieldDrafts[fieldKey] = nextValue
        vm.persistConfig()
      }

      function commitNumberField(fieldKey, target, key, options) {
        var rawValue
        var trimmedValue
        var numericValue
        var minValue
        var maxValue

        if (!fieldKey || !target || !key) {
          return
        }

        rawValue = normalizeFieldDraftValue(vm.ui.fieldDrafts[fieldKey])
        trimmedValue = rawValue.trim()
        minValue = Number(resolveValidationOption(options && options.min, target, key))
        maxValue = Number(resolveValidationOption(options && options.max, target, key))

        if (!trimmedValue) {
          markFieldInvalid(fieldKey)
          return
        }

        numericValue = Number(trimmedValue)
        if (!isFinite(numericValue)) {
          markFieldInvalid(fieldKey)
          return
        }

        if (options && options.integer && Math.round(numericValue) !== numericValue) {
          markFieldInvalid(fieldKey)
          return
        }

        if (isFinite(minValue) && numericValue < minValue) {
          markFieldInvalid(fieldKey)
          return
        }

        if (isFinite(maxValue) && numericValue > maxValue) {
          markFieldInvalid(fieldKey)
          return
        }

        if (options && options.integer) {
          numericValue = Math.round(numericValue)
        }

        target[key] = numericValue
        delete vm.ui.invalidFields[fieldKey]
        delete vm.ui.fieldLocks[fieldKey]
        if (vm.ui.activeFieldKey === fieldKey) {
          vm.ui.activeFieldKey = ''
        }
        vm.ui.fieldDrafts[fieldKey] = String(numericValue)
        vm.persistConfig()
      }

      function revertFieldDraft(fieldKey, fallbackValue) {
        if (!fieldKey) {
          return
        }

        vm.ui.fieldDrafts[fieldKey] = normalizeFieldDraftValue(fallbackValue)
        delete vm.ui.invalidFields[fieldKey]
        delete vm.ui.fieldLocks[fieldKey]
        if (vm.ui.activeFieldKey === fieldKey) {
          vm.ui.activeFieldKey = ''
        }
      }

      function invokeAction(expression) {
        vm.loading = true
        bngApi.engineLua(
          '(function() if not extensions.raceDirector then extensions.load("raceDirector") end return ' + expression + ' end)()',
          function (payload) {
            finishRefresh(function () {
              applyState(payload || {})
            })
          }
        )
      }

      function applyState(payload) {
        vm.state = {
          mapId: payload.mapId || '',
          mapLabel: payload.mapLabel || 'Unknown Map',
          configPath: payload.configPath || '',
          config: payload.config || buildDefaultConfig(),
          runtime: payload.runtime || buildDefaultRuntime(),
          vehicles: angular.isArray(payload.vehicles) ? payload.vehicles : [],
          options: payload.options || buildDefaultOptions()
        }
        syncAllFieldDrafts()
      }

      function finishRefresh(applyStateCallback) {
        $scope.$evalAsync(function () {
          applyStateCallback()
          vm.loading = false
        })
      }

      function buildDefaultState() {
        return {
          mapId: '',
          mapLabel: 'Unknown Map',
          configPath: '',
          config: buildDefaultConfig(),
          runtime: buildDefaultRuntime(),
          vehicles: [],
          options: buildDefaultOptions()
        }
      }

      function buildDefaultConfig() {
        return {
          presetName: 'Default TV Coverage',
          settings: {
            eventPriority: false,
            loopSequence: true
          },
          entries: []
        }
      }

      function buildDefaultRuntime() {
        return {
          playing: false,
          stateLabel: 'Idle',
          activeEntryId: '',
          activeEntryName: '',
          activeEntryType: '',
          nextEntryName: '',
          referenceVehName: '',
          pausedReason: '',
          message: '',
          isFreeCamera: false,
          raceTickerDetected: false,
          lastSwitchReason: ''
        }
      }

      function buildDefaultOptions() {
        return {
          onboardAngles: [
            { value: 'driver', label: 'Driver' },
            { value: 'onboard.hood', label: 'Hood' },
            { value: 'external', label: 'External' },
            { value: 'topDown', label: 'Topdown' }
          ],
          targetModes: [
            { value: 'racePosition', label: 'Race Position' },
            { value: 'randomCar', label: 'Random Car' },
            { value: 'specificCar', label: 'Specific Car' }
          ]
        }
      }

      function formatNumber(value) {
        var numericValue = Number(value)
        if (!isFinite(numericValue)) {
          return '--'
        }

        return (Math.round(numericValue * 10) / 10).toFixed(1)
      }

      function normalizeOptionValues(options, valueKey) {
        var values = []

        angular.forEach(options || [], function (option) {
          if (valueKey && option && typeof option === 'object') {
            values.push(option[valueKey])
            return
          }

          values.push(option)
        })

        return values
      }

      function lookupOptionLabel(options, value, fallbackLabel) {
        var index
        var option
        for (index = 0; index < (options || []).length; index++) {
          option = options[index]
          if (option && typeof option === 'object' && option.value === value) {
            return option.label || option.value
          }
          if (option === value) {
            return option
          }
        }

        return fallbackLabel || ''
      }

      function formatOnboardAngleLabel(value) {
        switch (value) {
          case 'driver':
            return 'Driver'
          case 'onboard.hood':
            return 'Hood'
          case 'external':
            return 'External'
          case 'topDown':
            return 'Topdown'
          default:
            return String(value || '')
        }
      }

      function registerWindowListeners() {
        if (typeof window === 'undefined' || !window.addEventListener) {
          return
        }

        window.addEventListener(UI_CONFIG_EVENT_NAME, onUiConfigChanged)
        window.addEventListener('resize', onViewportResized)

        $scope.$on('$destroy', function () {
          cancelWindowInteraction()
          cancelScheduledFrameApply()
          window.removeEventListener(UI_CONFIG_EVENT_NAME, onUiConfigChanged)
          window.removeEventListener('resize', onViewportResized)
          notifyWindowStateChanged()
        })
      }

      function onUiConfigChanged() {
        $scope.$evalAsync(function () {
          applyUiConfig(readLocalUiConfig())
        })
      }

      function applyUiConfig(config) {
        if (!config || typeof config !== 'object') {
          return
        }

        vm.settings.uiScale = normalizeUiScale(config.uiScale)
        vm.ui.scaleInput = formatUiScaleInput(vm.settings.uiScale)
      }

      function buildUiConfigSnapshot() {
        return {
          uiScale: normalizeUiScale(vm.settings.uiScale)
        }
      }

      function persistUiConfig() {
        var snapshot = buildUiConfigSnapshot()
        applyUiConfig(snapshot)
        writeLocalUiConfig(snapshot)
        notifyUiConfigChanged()
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

      function writeLocalUiConfig(config) {
        try {
          localStorage.setItem(UI_CONFIG_STORAGE_KEY, JSON.stringify(config))
        } catch (error) {
          return null
        }

        return true
      }

      function sanitizeCollapsedEntryState(value) {
        var result = {}
        angular.forEach(value, function (entryValue, entryId) {
          if (!entryId) {
            return
          }
          result[entryId] = !!entryValue
        })
        return result
      }

      function applyCollapsedEntryState(value) {
        vm.ui.collapsedEntries = sanitizeCollapsedEntryState(value)
      }

      function readCollapsedEntryState() {
        try {
          var rawValue = localStorage.getItem(SHOT_COLLAPSE_STORAGE_KEY)
          if (!rawValue) {
            return null
          }

          return JSON.parse(rawValue)
        } catch (error) {
          return null
        }
      }

      function persistCollapsedEntryState() {
        try {
          localStorage.setItem(
            SHOT_COLLAPSE_STORAGE_KEY,
            JSON.stringify(sanitizeCollapsedEntryState(vm.ui.collapsedEntries))
          )
        } catch (error) {
          return null
        }

        return true
      }

      function notifyUiConfigChanged() {
        if (typeof window === 'undefined' || !window.dispatchEvent || typeof Event !== 'function') {
          return
        }

        window.dispatchEvent(new Event(UI_CONFIG_EVENT_NAME))
      }

      function notifyWindowStateChanged() {
        if (typeof window === 'undefined' || !window.dispatchEvent || typeof Event !== 'function') {
          return
        }

        window.dispatchEvent(new Event(CONFIG_WINDOW_EVENT_NAME))
      }

      function onViewportResized() {
        scheduleFrameApply()
      }

      function resetLayoutDirtyFlag() {
        if (typeof window === 'undefined' || !window.UIAppStorage) {
          return
        }

        window.UIAppStorage.layoutDirty = false
      }

      function getUiScaleIndex(scale) {
        var targetValue = getUiScaleOption(scale).value
        var index
        for (index = 0; index < UI_SCALE_OPTIONS.length; index++) {
          if (UI_SCALE_OPTIONS[index].value === targetValue) {
            return index
          }
        }

        return 3
      }

      function getUiScaleOption(scale) {
        var numericScale = normalizeUiScale(scale)
        var bestOption = UI_SCALE_OPTIONS[0]
        var bestDistance = Math.abs(numericScale - bestOption.value)
        var index
        var option
        var distance

        for (index = 1; index < UI_SCALE_OPTIONS.length; index++) {
          option = UI_SCALE_OPTIONS[index]
          distance = Math.abs(numericScale - option.value)
          if (distance < bestDistance) {
            bestOption = option
            bestDistance = distance
          }
        }

        return bestOption
      }

      function normalizeUiScale(scale) {
        var numericScale = Number(scale)
        if (!isFinite(numericScale) || numericScale <= 0) {
          return 1
        }

        return numericScale
      }

      function parseUiScaleInput(inputValue, fallbackScale) {
        var rawText = String(inputValue == null ? '' : inputValue).trim()
        var hasPercent
        var numericValue
        if (!rawText) {
          return normalizeUiScale(fallbackScale)
        }

        hasPercent = rawText.indexOf('%') !== -1
        numericValue = Number(rawText.replace(/%/g, ''))
        if (!isFinite(numericValue) || numericValue <= 0) {
          return normalizeUiScale(fallbackScale)
        }

        if (hasPercent || numericValue >= 10) {
          return numericValue / 100
        }

        return numericValue
      }

      function formatUiScaleInput(scale) {
        var percentageValue = normalizeUiScale(scale) * 100
        var roundedValue = Math.round(percentageValue * 100) / 100
        return (Math.abs(roundedValue - Math.round(roundedValue)) < 0.0001)
          ? String(Math.round(roundedValue))
          : String(roundedValue)
      }

      function scheduleFrameApply() {
        if (typeof window === 'undefined') {
          return
        }

        if (vm.frameApplyHandle != null && window.cancelAnimationFrame) {
          window.cancelAnimationFrame(vm.frameApplyHandle)
          vm.frameApplyHandle = null
        }

        if (window.requestAnimationFrame) {
          vm.frameApplyHandle = window.requestAnimationFrame(function () {
            vm.frameApplyHandle = null
            applySavedWindowFrame()
          })
          return
        }

        vm.frameApplyHandle = window.setTimeout(function () {
          vm.frameApplyHandle = null
          applySavedWindowFrame()
        }, 0)
      }

      function cancelScheduledFrameApply() {
        if (typeof window === 'undefined' || vm.frameApplyHandle == null) {
          return
        }

        if (window.cancelAnimationFrame) {
          window.cancelAnimationFrame(vm.frameApplyHandle)
        } else {
          window.clearTimeout(vm.frameApplyHandle)
        }

        vm.frameApplyHandle = null
      }

      function ensureHostNode() {
        var containerId
        if (vm.hostNode && vm.hostNode.parentNode && vm.containerNode && vm.containerNode.parentNode) {
          return true
        }

        vm.hostNode = findHostNode(vm.rootNode)
        if (!vm.hostNode) {
          return false
        }

        containerId = vm.hostNode.getAttribute('containerid')
        if (UIAppStorage && UIAppStorage.containers && containerId != null && UIAppStorage.containers[containerId]) {
          vm.containerNode = UIAppStorage.containers[containerId]
        } else {
          vm.containerNode = vm.hostNode.parentNode || null
        }

        if (!vm.containerNode) {
          return false
        }

        resetFloatingAnchors()
        return true
      }

      function applySavedWindowFrame() {
        var frame
        if (!ensureHostNode()) {
          return
        }

        frame = readWindowFrame()
        if (!frame) {
          frame = readHostFrame()
        }

        applyWindowFrame(frame, false)
      }

      function applyWindowFrame(frame, skipPersist) {
        var normalizedFrame
        if (!ensureHostNode()) {
          return null
        }

        normalizedFrame = normalizeWindowFrame(frame)
        resetFloatingAnchors()
        vm.hostNode.style.left = normalizedFrame.left + 'px'
        vm.hostNode.style.top = normalizedFrame.top + 'px'
        vm.hostNode.style.width = normalizedFrame.width + 'px'
        vm.hostNode.style.height = normalizedFrame.height + 'px'
        UiAppsService.restrictInWindow(vm.containerNode, vm.hostNode)
        normalizedFrame = readHostFrame()

        if (!skipPersist) {
          writeWindowFrame(normalizedFrame)
        }

        return normalizedFrame
      }

      function normalizeWindowFrame(frame) {
        var viewport = getViewportSize()
        var maxWidth = Math.max(360, viewport.width - (WINDOW_SNAP_PX * 2))
        var maxHeight = Math.max(280, viewport.height - (WINDOW_SNAP_PX * 2))
        var minWidth = Math.min(MIN_WINDOW_WIDTH, maxWidth)
        var minHeight = Math.min(MIN_WINDOW_HEIGHT, maxHeight)
        var safeFrame = frame || {}
        var width = clamp(Math.round(Number(safeFrame.width) || 900), minWidth, maxWidth)
        var height = clamp(Math.round(Number(safeFrame.height) || 720), minHeight, maxHeight)
        var leftDefault = Math.round((viewport.width - width) / 2)
        var topDefault = WINDOW_SNAP_PX
        var rawLeft = Math.round(Number(safeFrame.left))
        var rawTop = Math.round(Number(safeFrame.top))
        var left = isFinite(rawLeft)
          ? clamp(rawLeft, WINDOW_SNAP_PX, viewport.width - width - WINDOW_SNAP_PX)
          : clamp(leftDefault, WINDOW_SNAP_PX, viewport.width - width - WINDOW_SNAP_PX)
        var top = isFinite(rawTop)
          ? clamp(rawTop, WINDOW_SNAP_PX, viewport.height - height - WINDOW_SNAP_PX)
          : clamp(topDefault, WINDOW_SNAP_PX, viewport.height - height - WINDOW_SNAP_PX)

        return {
          left: left,
          top: top,
          width: width,
          height: height
        }
      }

      function beginWindowInteraction($event, cursorStyle) {
        if (!getMouseEvent($event) || !ensureHostNode()) {
          return false
        }

        if ($event && typeof $event.preventDefault === 'function') {
          $event.preventDefault()
        }
        if ($event && typeof $event.stopPropagation === 'function') {
          $event.stopPropagation()
        }

        cancelWindowInteraction()
        $document.on('mousemove', onWindowPointerMove)
        $document.on('mouseup', endWindowInteraction)
        if (document.body && document.body.style) {
          document.body.style.userSelect = 'none'
          document.body.style.cursor = cursorStyle || 'move'
        }

        return true
      }

      function onWindowPointerMove(event) {
        var sourceEvent = getMouseEvent(event)
        var left
        var top
        var width
        var height
        if (!sourceEvent || !ensureHostNode()) {
          return
        }

        if (vm.dragSession) {
          left = clamp(
            Math.round((sourceEvent.pageX - vm.dragSession.containerRect.x) - vm.dragSession.startX),
            0,
            vm.dragSession.maxLeft
          )
          top = clamp(
            Math.round((sourceEvent.pageY - vm.dragSession.containerRect.y) - vm.dragSession.startY),
            0,
            vm.dragSession.maxTop
          )

          resetFloatingAnchors()
          vm.hostNode.style.left = left + 'px'
          vm.hostNode.style.top = top + 'px'
        } else if (vm.resizeSession) {
          width = clamp(
            Math.round((sourceEvent.pageX - vm.resizeSession.containerRect.x) - vm.resizeSession.startX),
            MIN_WINDOW_WIDTH,
            vm.resizeSession.maxWidth
          )
          height = clamp(
            Math.round((sourceEvent.pageY - vm.resizeSession.containerRect.y) - vm.resizeSession.startY),
            MIN_WINDOW_HEIGHT,
            vm.resizeSession.maxHeight
          )

          resetFloatingAnchors()
          vm.hostNode.style.width = width + 'px'
          vm.hostNode.style.height = height + 'px'
        }
      }

      function endWindowInteraction() {
        if (vm.hostNode && (vm.dragSession || vm.resizeSession)) {
          UiAppsService.restrictInWindow(vm.containerNode, vm.hostNode)
          writeWindowFrame(normalizeWindowFrame(readHostFrame()))
        }

        cancelWindowInteraction()
      }

      function cancelWindowInteraction() {
        vm.dragSession = null
        vm.resizeSession = null

        if (typeof document === 'undefined') {
          return
        }

        $document.off('mousemove', onWindowPointerMove)
        $document.off('mouseup', endWindowInteraction)

        if (document.body && document.body.style) {
          document.body.style.userSelect = ''
          document.body.style.cursor = ''
        }
      }

      function findHostNode(node) {
        var currentNode = node
        while (currentNode && currentNode !== document && currentNode.nodeType === 1) {
          if (hasClass(currentNode, 'bng-app')) {
            return currentNode
          }

          currentNode = currentNode.parentNode
        }

        return null
      }

      function hasClass(node, className) {
        if (!node) {
          return false
        }

        if (node.classList && typeof node.classList.contains === 'function') {
          return node.classList.contains(className)
        }

        return new RegExp('(^|\\s)' + className + '(\\s|$)').test(node.className || '')
      }

      function resetFloatingAnchors() {
        if (!vm.hostNode || !vm.hostNode.style) {
          return
        }

        vm.hostNode.style.right = 'auto'
        vm.hostNode.style.bottom = 'auto'
        vm.hostNode.style.minWidth = MIN_WINDOW_WIDTH + 'px'
        vm.hostNode.style.minHeight = MIN_WINDOW_HEIGHT + 'px'
      }

      function getViewportSize() {
        var width = (vm.containerNode && vm.containerNode.clientWidth) ? vm.containerNode.clientWidth : ((typeof window !== 'undefined' && window.innerWidth) ? window.innerWidth : 1920)
        var height = (vm.containerNode && vm.containerNode.clientHeight) ? vm.containerNode.clientHeight : ((typeof window !== 'undefined' && window.innerHeight) ? window.innerHeight : 1080)

        return {
          width: Math.max(360, width),
          height: Math.max(280, height)
        }
      }

      function getMouseEvent(event) {
        var sourceEvent = event && (event.originalEvent || event)
        if (!sourceEvent) {
          return null
        }

        if (isFinite(sourceEvent.pageX) && isFinite(sourceEvent.pageY)) {
          return sourceEvent
        }

        return null
      }

      function readHostFrame() {
        if (!vm.hostNode) {
          return null
        }

        return {
          left: vm.hostNode.offsetLeft,
          top: vm.hostNode.offsetTop,
          width: vm.hostNode.offsetWidth,
          height: vm.hostNode.offsetHeight
        }
      }

      function readWindowFrame() {
        try {
          var rawValue = localStorage.getItem(WINDOW_FRAME_STORAGE_KEY)
          if (!rawValue) {
            return null
          }

          return JSON.parse(rawValue)
        } catch (error) {
          return null
        }
      }

      function writeWindowFrame(frame) {
        try {
          localStorage.setItem(WINDOW_FRAME_STORAGE_KEY, JSON.stringify(frame))
        } catch (error) {
          return null
        }

        return true
      }

      function writeConfigWindowPreference(isOpen) {
        try {
          localStorage.setItem(CONFIG_WINDOW_STORAGE_KEY, isOpen ? 'true' : 'false')
        } catch (error) {
          return null
        }

        return true
      }

      function clamp(value, minValue, maxValue) {
        if (!isFinite(value)) {
          return minValue
        }

        if (maxValue < minValue) {
          return minValue
        }

        return Math.max(minValue, Math.min(maxValue, value))
      }
    }],
    controllerAs: 'raceDirectorConfig'
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
