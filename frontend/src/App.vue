<template>
  <div v-if="authBooting" class="app-loading-shell">
    <div class="app-loading-card">
      <div class="brand-mark"><span></span></div>
      <strong>{{ BRAND.productName }}</strong>
      <span>正在连接平台服务...</span>
    </div>
  </div>

  <Login v-else-if="!isLoggedIn" :on-login="performLogin" @login-success="handleLoginSuccess" />

  <div v-else class="dashboard-container">
    <AppHeader :bindings="headerBindings" />
    <div class="main-content">
      <LeftPanel :bindings="leftPanelBindings" />
      <section class="workspace-center">
        <div class="workspace-map-card">
          <div class="workspace-card-header">
            <div>
              <h2>远程管理总览</h2>
              <p class="workspace-caption">保留设备、告警、证据和配置下发能力，只展示最关键的信息。</p>
            </div>
            <div class="workspace-card-meta">
              <span class="workspace-meta-item">{{ activeModuleLabel }}</span>
              <span class="workspace-meta-item">{{ currentTime }}</span>
            </div>
          </div>
          <div id="map-container" class="map-center"></div>
          <MapController :bindings="mapControllerBindings" />
        </div>
      </section>
      <RightPanel :bindings="rightPanelBindings" />
    </div>
    <AppDialogs :bindings="dialogsBindings" />
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import * as echarts from 'echarts'
import L from 'leaflet'
import { ElMessage, ElMessageBox, ElNotification } from 'element-plus'

import Login from './components/Login.vue'
import AppHeader from './components/app/AppHeader.vue'
import LeftPanel from './components/app/LeftPanel.vue'
import MapController from './components/app/MapController.vue'
import RightPanel from './components/app/RightPanel.vue'
import AppDialogs from './components/app/AppDialogs.vue'
import { BRAND } from './config/brand'

const STORAGE_TOKEN_KEY = 'mf_monitor_platform_token'
const STORAGE_USER_KEY = 'mf_monitor_platform_user'
const MONITOR_BASE = '/monitor/'
const DEFAULT_CENTER = [35.8, 104.1]
const DEFAULT_ZOOM = 5
const GAODE_SUBDOMAINS = ['1', '2', '3', '4']
const SATELLITE_TILE_URL = 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}'
const SATELLITE_LABEL_URL = 'https://webst0{s}.is.autonavi.com/appmaptile?style=8&x={x}&y={y}&z={z}'
const STREET_TILE_URL = 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}'

function createEmptySummary() {
  return {
    cards: {
      devices_total: 0,
      devices_online: 0,
      devices_offline: 0,
      devices_unknown: 0,
      devices_enabled: 0,
      devices_disabled: 0,
      open_alarms: 0,
      classification_window: 0,
      speed_window: 0,
    },
    devices: [],
    map_points: [],
    latest_alarms: [],
    hotspot_rules: [],
    disaster_mix: [],
  }
}

const authBooting = ref(true)
const isLoggedIn = ref(false)
const accessToken = ref(localStorage.getItem(STORAGE_TOKEN_KEY) || '')
const currentUser = ref(null)

try {
  const rawUser = localStorage.getItem(STORAGE_USER_KEY)
  if (rawUser) currentUser.value = JSON.parse(rawUser)
} catch {
  currentUser.value = null
}

const currentTime = ref('')
const isRefreshing = ref(false)
const activeModule = ref('overview')
const timeWindowHours = ref(24)
const bucketMinutes = ref(60)
const mapMode = ref('street')
const mapDeviceFilter = ref('all')

const summary = ref(createEmptySummary())
const trends = ref({ buckets: [] })
const deviceOverview = ref({ items: [], total: 0, summary: {} })
const alarms = ref([])
const alarmRules = ref([])
const platformUsers = ref([])
const deviceCommands = ref([])
const deviceClassificationRecords = ref([])

const deviceKeyword = ref('')
const deviceOnlineFilter = ref('all')
const alarmSeverityFilter = ref('all')
const alarmStatusFilter = ref('all')
const alarmEventFilter = ref('all')

const selectedDevice = ref(null)
const selectedAlarm = ref(null)

const showDeviceDialog = ref(false)
const showSingleDeviceDialog = ref(false)
const showWarningDetailDialog = ref(false)
const showReportDialog = ref(false)
const showConfigPushDialog = ref(false)
const showUserManageDialog = ref(false)
const submittingConfig = ref(false)
const submittingUser = ref(false)

const reportWindowHours = ref(24)
const configTargetDevice = ref(null)
const configForm = reactive({
  config_name: 'sampling_profile',
  payload_text: '{\n  "interval": 3\n}',
  qos: 1,
  retain: false,
})
const userForm = reactive({
  username: '',
  display_name: '',
  password: '',
  role: 'viewer',
  enabled: true,
})

let map = null
let baseLayer = null
let roadLayer = null
let deviceLayerGroup = null
let trendChart = null
let trendChartElement = null
let clockTimer = null

const isAdmin = computed(() => currentUser.value?.role === 'admin' || currentUser.value?.via_api_key)
const canOperate = computed(() => isAdmin.value || currentUser.value?.role === 'operator')
const moduleOptions = computed(() => {
  const items = [
    { label: '监测地点', value: 'overview' },
    { label: '监测设备', value: 'devices' },
    { label: '告警中心', value: 'alarms' },
    { label: '数据报表', value: 'reports' },
  ]
  if (isAdmin.value) items.push({ label: '系统管理', value: 'settings' })
  return items
})
const activeModuleLabel = computed(() => moduleOptions.value.find((item) => item.value === activeModule.value)?.label || '监测地点')
const cards = computed(() => summary.value.cards || {})
const hotspotRules = computed(() => summary.value.hotspot_rules || [])
const disasterMix = computed(() => summary.value.disaster_mix || [])
const configTargetDeviceLabel = computed(() => (configTargetDevice.value ? `${configTargetDevice.value.aibox_id} / ${configTargetDevice.value.cam_id}` : '-'))
const statusText = computed(() => {
  if (cards.value.open_alarms > 0) return `当前存在 ${cards.value.open_alarms} 条待处置告警`
  if (cards.value.devices_offline > 0) return `当前有 ${cards.value.devices_offline} 台设备离线`
  return '平台运行正常'
})
const statusType = computed(() => {
  if (cards.value.open_alarms > 0) return 'danger'
  if (cards.value.devices_offline > 0) return 'warning'
  return 'success'
})

const allDevices = computed(() => deviceOverview.value.items || [])
const filteredDevices = computed(() => {
  const keyword = deviceKeyword.value.trim().toLowerCase()
  return allDevices.value.filter((item) => {
    const onlineStatus = item.status?.online_status || 'unknown'
    const matchesStatus = deviceOnlineFilter.value === 'all' || onlineStatus === deviceOnlineFilter.value
    const haystack = `${item.aibox_id} ${item.cam_id} ${item.device_name || ''} ${item.location?.location || ''}`.toLowerCase()
    const matchesKeyword = !keyword || haystack.includes(keyword)
    return matchesStatus && matchesKeyword
  })
})
const filteredAlarms = computed(() => alarms.value.filter((item) => {
  const severityOk = alarmSeverityFilter.value === 'all' || item.severity === alarmSeverityFilter.value
  const statusOk = alarmStatusFilter.value === 'all' || item.status === alarmStatusFilter.value
  const eventOk = alarmEventFilter.value === 'all' || item.event_type === alarmEventFilter.value
  return severityOk && statusOk && eventOk
}))
const latestAlarms = computed(() => (activeModule.value === 'alarms' ? filteredAlarms.value : (summary.value.latest_alarms || alarms.value)).slice(0, 12))
const deviceList = computed(() => filteredDevices.value.slice(0, 12))
const filteredMapPoints = computed(() => (summary.value.map_points || []).filter((item) => {
  const status = item.online_status || 'unknown'
  if (mapDeviceFilter.value === 'on' && status !== 'on') return false
  if (mapDeviceFilter.value === 'off' && status !== 'off') return false
  if (mapDeviceFilter.value === 'alarm' && Number(item.open_alarm_count || 0) <= 0) return false
  return true
}))

function normalizeMonitorPath() {
  if (window.location.pathname !== MONITOR_BASE) {
    window.history.replaceState(null, '', MONITOR_BASE)
  }
}

function persistSession(token, user) {
  accessToken.value = token
  currentUser.value = user
  localStorage.setItem(STORAGE_TOKEN_KEY, token)
  localStorage.setItem(STORAGE_USER_KEY, JSON.stringify(user))
}

function clearSession() {
  accessToken.value = ''
  currentUser.value = null
  isLoggedIn.value = false
  localStorage.removeItem(STORAGE_TOKEN_KEY)
  localStorage.removeItem(STORAGE_USER_KEY)
}

function destroyRuntimeViews() {
  if (trendChart) {
    trendChart.dispose()
    trendChart = null
  }
  trendChartElement = null
  if (map) {
    map.remove()
    map = null
  }
  baseLayer = null
  roadLayer = null
  deviceLayerGroup = null
}

async function parseApiResponse(response) {
  const contentType = response.headers.get('content-type') || ''
  const body = contentType.includes('application/json') ? await response.json() : await response.text()
  if (!response.ok) {
    const message = typeof body === 'string' ? body : body?.message || body?.detail || '请求失败'
    throw new Error(message)
  }
  return body
}

async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {})
  if (accessToken.value) headers.set('Authorization', `Bearer ${accessToken.value}`)
  const isJsonBody = options.body && !(options.body instanceof FormData) && typeof options.body !== 'string' && !(options.body instanceof Blob)
  if (isJsonBody) headers.set('Content-Type', 'application/json')
  const response = await fetch(path, {
    ...options,
    headers,
    body: isJsonBody ? JSON.stringify(options.body) : options.body,
  })
  if (response.status === 401 && path !== '/api/auth/login') {
    clearSession()
    authBooting.value = false
    throw new Error('登录状态已失效，请重新登录。')
  }
  return parseApiResponse(response)
}

async function performLogin(payload) {
  return apiFetch('/api/auth/login', { method: 'POST', body: { username: payload.username, password: payload.password } })
}

async function handleLoginSuccess(result) {
  persistSession(result.access_token, result.user)
  isLoggedIn.value = true
  normalizeMonitorPath()
  await nextTick()
  initMap()
  await refreshPlatform()
}

async function bootstrapAuth() {
  normalizeMonitorPath()
  currentTime.value = new Date().toLocaleString('zh-CN', { hour12: false }).replace(/\//g, '-')
  clockTimer = window.setInterval(() => {
    currentTime.value = new Date().toLocaleString('zh-CN', { hour12: false }).replace(/\//g, '-')
  }, 1000)
  if (!accessToken.value) {
    authBooting.value = false
    return
  }
  try {
    const me = await apiFetch('/api/auth/me')
    currentUser.value = me
    isLoggedIn.value = true
    await nextTick()
    initMap()
    await refreshPlatform()
  } catch {
    clearSession()
  } finally {
    authBooting.value = false
  }
}
async function logoutPlatform() {
  try {
    await apiFetch('/api/auth/logout', { method: 'POST' })
  } catch {}
  destroyRuntimeViews()
  clearSession()
  selectedDevice.value = null
  selectedAlarm.value = null
  deviceCommands.value = []
  deviceClassificationRecords.value = []
  showUserManageDialog.value = false
  showConfigPushDialog.value = false
}

function changeModule(module) {
  activeModule.value = module
}

function setTrendChartRef(element) {
  trendChartElement = element
  renderTrendChart()
}

function initMap() {
  const container = document.getElementById('map-container')
  if (!container || map) {
    renderDeviceMarkers()
    return
  }
  map = L.map(container, { zoomControl: false }).setView(DEFAULT_CENTER, DEFAULT_ZOOM)
  const initialBaseUrl = mapMode.value === 'satellite' ? SATELLITE_TILE_URL : STREET_TILE_URL
  baseLayer = L.tileLayer(initialBaseUrl, {
    maxZoom: 18,
    attribution: '高德地图',
    subdomains: GAODE_SUBDOMAINS,
  }).addTo(map)
  roadLayer = L.tileLayer(SATELLITE_LABEL_URL, {
    maxZoom: 18,
    opacity: 0.88,
    attribution: '高德地图',
    subdomains: GAODE_SUBDOMAINS,
  })
  if (mapMode.value === 'satellite') {
    roadLayer.addTo(map)
  }
  deviceLayerGroup = L.layerGroup().addTo(map)
  requestAnimationFrame(() => map?.invalidateSize())
  renderDeviceMarkers()
}

function setMapMode(mode) {
  if (!map || !baseLayer) return
  if (mode === 'satellite') {
    baseLayer.setUrl(SATELLITE_TILE_URL)
    baseLayer.options.attribution = '高德地图'
    baseLayer.options.subdomains = GAODE_SUBDOMAINS
    if (!map.hasLayer(roadLayer)) roadLayer.addTo(map)
  } else {
    baseLayer.setUrl(STREET_TILE_URL)
    baseLayer.options.attribution = '高德地图'
    baseLayer.options.subdomains = GAODE_SUBDOMAINS
    if (map.hasLayer(roadLayer)) map.removeLayer(roadLayer)
  }
  requestAnimationFrame(() => map?.invalidateSize())
}

function resetMapView() {
  if (map) map.flyTo(DEFAULT_CENTER, DEFAULT_ZOOM, { duration: 1.1 })
}

function handleWindowResize() {
  renderTrendChart()
  if (map) {
    requestAnimationFrame(() => map?.invalidateSize())
  }
}

function focusDeviceOnMap(device) {
  if (!map) return
  const lat = Number(device?.location?.latitude)
  const lng = Number(device?.location?.longitude)
  if (Number.isFinite(lat) && Number.isFinite(lng)) map.flyTo([lat, lng], 11, { duration: 1.1 })
}

function renderDeviceMarkers() {
  if (!map || !deviceLayerGroup) return
  deviceLayerGroup.clearLayers()
  filteredMapPoints.value.forEach((item) => {
    const lat = Number(item.latitude)
    const lng = Number(item.longitude)
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return
    const status = item.online_status === 'on' ? 'online' : 'offline'
    const markerHtml = `<div class="custom-marker marker-${status}"><div class="pulse"></div><span class="marker-count">${Number(item.open_alarm_count || 0)}</span></div>`
    const icon = L.divIcon({ className: 'custom-div-icon', html: markerHtml, iconSize: [28, 28], iconAnchor: [14, 14] })
    const marker = L.marker([lat, lng], { icon })
    marker.bindPopup(`<div class="map-popup-card"><div class="popup-title">${item.label || `${item.aibox_id}-${item.cam_id}`}</div><div class="popup-row">位置：${item.location || '未登记'}</div><div class="popup-row">状态：${item.online_status === 'on' ? '在线' : '离线'}</div><div class="popup-row">识别记录：${item.classification_count_window || 0}</div><div class="popup-row">流速记录：${item.speed_count_window || 0}</div><div class="popup-row">开放告警：${item.open_alarm_count || 0}</div></div>`)
    marker.on('click', () => {
      const matched = allDevices.value.find((device) => device.id === item.id || (device.aibox_id === item.aibox_id && device.cam_id === item.cam_id))
      if (matched) openDeviceDetail(matched)
    })
    deviceLayerGroup.addLayer(marker)
  })
}

function renderTrendChart() {
  if (!trendChartElement) return
  if (!trendChart) trendChart = echarts.init(trendChartElement)
  const buckets = trends.value.buckets || []
  trendChart.setOption({
    backgroundColor: 'transparent',
    tooltip: { trigger: 'axis' },
    legend: { top: 8, textStyle: { color: '#54657d' }, data: ['识别记录', '流速记录', '告警数量'] },
    grid: { left: 36, right: 16, top: 44, bottom: 24 },
    xAxis: { type: 'category', boundaryGap: false, data: buckets.map((item) => formatAxisLabel(item.ts)), axisLabel: { color: '#6f8296', fontSize: 11 }, axisLine: { lineStyle: { color: 'rgba(110,131,154,0.25)' } } },
    yAxis: { type: 'value', axisLabel: { color: '#6f8296' }, splitLine: { lineStyle: { color: 'rgba(110,131,154,0.12)' } } },
    series: [
      { name: '识别记录', type: 'line', smooth: true, showSymbol: false, lineStyle: { width: 3, color: '#1f5ea8' }, areaStyle: { color: 'rgba(31,94,168,0.12)' }, data: buckets.map((item) => item.classification_count || 0) },
      { name: '流速记录', type: 'line', smooth: true, showSymbol: false, lineStyle: { width: 3, color: '#13b6b3' }, areaStyle: { color: 'rgba(19,182,179,0.12)' }, data: buckets.map((item) => item.speed_count || 0) },
      { name: '告警数量', type: 'line', smooth: true, showSymbol: false, lineStyle: { width: 3, color: '#f56c6c' }, areaStyle: { color: 'rgba(245,108,108,0.12)' }, data: buckets.map((item) => item.alarm_count || 0) },
    ],
  })
}

function formatAxisLabel(value) {
  return value ? String(value).replace('T', ' ').slice(5, 16) : '-'
}

function formatTime(value) {
  return value ? String(value).replace('T', ' ').replace('+08:00', '') : '-'
}

async function fetchSummary() {
  summary.value = await apiFetch(`/api/dashboard/summary?hours=${timeWindowHours.value}`)
}

async function fetchTrends() {
  trends.value = await apiFetch(`/api/dashboard/trends?hours=${timeWindowHours.value}&bucket_minutes=${bucketMinutes.value}`)
}

async function fetchDeviceOverview() {
  deviceOverview.value = await apiFetch('/api/device_overview')
}

async function fetchAlarms() {
  alarms.value = await apiFetch('/api/alarms')
}

async function fetchRules() {
  alarmRules.value = await apiFetch('/api/alarm_rules')
}

async function fetchUsersIfNeeded() {
  platformUsers.value = isAdmin.value ? await apiFetch('/api/platform_users') : []
}

async function refreshPlatform() {
  if (!isLoggedIn.value) return
  isRefreshing.value = true
  try {
    await Promise.all([fetchSummary(), fetchTrends(), fetchDeviceOverview(), fetchAlarms(), fetchRules(), fetchUsersIfNeeded()])
    if (selectedDevice.value) {
      const refreshedDevice = allDevices.value.find((item) => item.id === selectedDevice.value.id)
      selectedDevice.value = refreshedDevice || null
      if (selectedDevice.value) {
        await Promise.all([
          loadDeviceCommands(selectedDevice.value.id),
          loadDeviceClassificationRecords(selectedDevice.value.aibox_id, selectedDevice.value.cam_id),
        ])
      } else {
        deviceCommands.value = []
        deviceClassificationRecords.value = []
      }
    }
    if (selectedAlarm.value) selectedAlarm.value = alarms.value.find((item) => item.id === selectedAlarm.value.id) || null
    await nextTick()
    initMap()
    renderDeviceMarkers()
    renderTrendChart()
  } catch (error) {
    ElNotification({ title: '数据刷新失败', message: error.message || '平台数据读取失败，请稍后重试。', type: 'error' })
  } finally {
    isRefreshing.value = false
  }
}

async function reloadWindow() {
  await Promise.all([fetchSummary(), fetchTrends()])
  renderDeviceMarkers()
  renderTrendChart()
}

async function quickRefresh() {
  await refreshPlatform()
}

async function loadDeviceCommands(deviceId) {
  deviceCommands.value = await apiFetch(`/api/device_commands?device_id=${deviceId}`)
}

async function loadDeviceClassificationRecords(aiboxId, camId) {
  deviceClassificationRecords.value = await apiFetch(
    `/api/classification?aibox_id=${encodeURIComponent(aiboxId)}&cam_id=${encodeURIComponent(camId)}`
  )
}

async function openDeviceDetail(device) {
  selectedDevice.value = device
  showSingleDeviceDialog.value = true
  try {
    await Promise.all([
      loadDeviceCommands(device.id),
      loadDeviceClassificationRecords(device.aibox_id, device.cam_id),
    ])
  } catch (error) {
    ElNotification({ title: '读取设备指令失败', message: error.message || '无法获取设备下发记录。', type: 'warning' })
  }
  focusDeviceOnMap(device)
  activeModule.value = 'devices'
}

function handleDeviceRowClick(device) {
  openDeviceDetail(device)
}

function openAlarmDetail(alarm) {
  selectedAlarm.value = alarm
  showWarningDetailDialog.value = true
  activeModule.value = 'alarms'
}

function handleAlarmRowClick(alarm) {
  openAlarmDetail(alarm)
}
function openDeviceDialog() {
  showDeviceDialog.value = true
  activeModule.value = 'devices'
}

function openReportDialog() {
  reportWindowHours.value = timeWindowHours.value
  showReportDialog.value = true
  activeModule.value = 'reports'
}

function openUserDialog() {
  if (isAdmin.value) {
    showUserManageDialog.value = true
    activeModule.value = 'settings'
  }
}

async function ackAlarm(alarm) {
  await apiFetch(`/api/alarms/${alarm.id}/ack`, { method: 'POST' })
  ElMessage.success('告警已确认')
  showWarningDetailDialog.value = false
  await refreshPlatform()
}

async function closeAlarm(alarm) {
  await apiFetch(`/api/alarms/${alarm.id}/close`, { method: 'POST' })
  ElMessage.success('告警已关闭')
  showWarningDetailDialog.value = false
  await refreshPlatform()
}

async function toggleDeviceEnabled(device) {
  await apiFetch(`/api/devices/${device.id}/enabled`, { method: 'PATCH', body: { enabled: !device.enabled } })
  ElMessage.success(device.enabled ? '设备已停用' : '设备已启用')
  await refreshPlatform()
}

function openConfigDialog(device) {
  configTargetDevice.value = device
  configForm.config_name = 'sampling_profile'
  configForm.payload_text = '{\n  "interval": 3\n}'
  configForm.qos = 1
  configForm.retain = false
  showConfigPushDialog.value = true
}

async function submitConfigPush() {
  if (!configTargetDevice.value) return
  submittingConfig.value = true
  try {
    await apiFetch(`/api/devices/${configTargetDevice.value.id}/config`, { method: 'POST', body: { config_name: configForm.config_name, payload: JSON.parse(configForm.payload_text || '{}'), qos: configForm.qos, retain: configForm.retain } })
    ElMessage.success('配置已下发')
    showConfigPushDialog.value = false
    await loadDeviceCommands(configTargetDevice.value.id)
  } catch (error) {
    ElNotification({ title: '配置下发失败', message: error.message || '请检查配置内容是否为合法 JSON。', type: 'error' })
  } finally {
    submittingConfig.value = false
  }
}

async function createPlatformUser() {
  submittingUser.value = true
  try {
    await apiFetch('/api/platform_users', { method: 'POST', body: { username: userForm.username.trim(), display_name: userForm.display_name.trim(), password: userForm.password, role: userForm.role, enabled: userForm.enabled } })
    userForm.username = ''
    userForm.display_name = ''
    userForm.password = ''
    userForm.role = 'viewer'
    userForm.enabled = true
    ElMessage.success('用户创建成功')
    await fetchUsersIfNeeded()
  } catch (error) {
    ElNotification({ title: '创建用户失败', message: error.message || '请检查用户名是否重复。', type: 'error' })
  } finally {
    submittingUser.value = false
  }
}

async function downloadReportCsv() {
  try {
    const response = await fetch(`/api/dashboard/report.csv?hours=${reportWindowHours.value}`, { headers: { Authorization: `Bearer ${accessToken.value}` } })
    if (!response.ok) throw new Error(await response.text())
    const blob = await response.blob()
    const url = window.URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = `${BRAND.shortName}_报表_${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.csv`
    anchor.click()
    window.URL.revokeObjectURL(url)
    ElMessage.success('报表已导出')
  } catch (error) {
    ElNotification({ title: '报表导出失败', message: error.message || '请稍后重试。', type: 'error' })
  }
}

async function handleUserCommand(command) {
  if (command === 'users') {
    openUserDialog()
    return
  }
  if (command === 'logout') {
    const confirmed = await ElMessageBox.confirm('确认退出当前系统登录状态吗？', '退出登录', { type: 'warning', confirmButtonText: '确认退出', cancelButtonText: '取消' }).catch(() => false)
    if (confirmed) await logoutPlatform()
  }
}

const headerBindings = { currentTime, currentUser, activeModule, activeModuleLabel, moduleOptions, changeModule, openReportDialog, handleUserCommand, quickRefresh, isAdmin, statusText, statusType }
const leftPanelBindings = { cards, changeModule, openDeviceDialog, openReportDialog, activeModule, moduleOptions, timeWindowHours, bucketMinutes, reloadWindow, setTrendChartRef, deviceKeyword, deviceOnlineFilter, filteredDevices, handleDeviceRowClick, alarmSeverityFilter, alarmStatusFilter, alarmEventFilter, filteredAlarms, handleAlarmRowClick, platformUsers, alarmRules, openUserDialog }
const mapControllerBindings = { mapMode, setMapMode, mapDeviceFilter, resetMapView }
const rightPanelBindings = { activeModule, latestAlarms, deviceList, selectedDevice, selectedAlarm, deviceCommands, deviceClassificationRecords, hotspotRules, disasterMix, platformUsers, openAlarmDetail, openDeviceDetail, formatTime }
const dialogsBindings = { showDeviceDialog, allDevices, openDeviceDetail, showSingleDeviceDialog, selectedDevice, isAdmin, canOperate, toggleDeviceEnabled, openConfigDialog, showWarningDetailDialog, selectedAlarm, formatTime, ackAlarm, closeAlarm, showReportDialog, reportWindowHours, downloadReportCsv, showConfigPushDialog, configForm, submittingConfig, submitConfigPush, configTargetDeviceLabel, showUserManageDialog, platformUsers, userForm, submittingUser, createPlatformUser }

watch(mapMode, (value) => setMapMode(value))
watch(filteredMapPoints, () => renderDeviceMarkers(), { deep: true })
watch(activeModule, async () => {
  await nextTick()
  renderTrendChart()
})

onMounted(() => {
  bootstrapAuth()
  window.addEventListener('resize', handleWindowResize)
})

onBeforeUnmount(() => {
  if (clockTimer) clearInterval(clockTimer)
  window.removeEventListener('resize', handleWindowResize)
  destroyRuntimeViews()
})
</script>

<style>
.dashboard-container {
  display: flex;
  flex-direction: column;
  height: 100vh;
  background: #f3f5f7;
  color: #1f2933;
}

.main-content {
  flex: 1;
  min-height: 0;
  display: grid;
  grid-template-columns: 320px minmax(0, 1fr) 360px;
  gap: 16px;
  padding: 16px;
  overflow: hidden;
}

.app-loading-shell {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f3f5f7;
}

.app-loading-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  min-width: 260px;
  padding: 32px 36px;
  border-radius: 16px;
  background: #ffffff;
  color: #1f2933;
  border: 1px solid #dde3ea;
  box-shadow: 0 8px 24px rgba(15, 23, 42, 0.06);
}

.brand-mark {
  width: 52px;
  height: 52px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #1f5ea8;
}

.brand-mark span {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: #ffffff;
}

.title {
  margin: 0;
  font-size: 24px;
  font-weight: 700;
  color: #16212b;
}

.title-sub {
  margin: 4px 0 0;
  font-size: 12px;
  color: #6b7785;
}

.top-header {
  min-height: 68px;
  padding: 0 20px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: #ffffff;
  border-bottom: 1px solid #dde3ea;
  z-index: 1000;
}

.logo-area {
  display: flex;
  align-items: center;
  gap: 12px;
}

.custom-logo {
  width: 44px;
  height: 44px;
}

.status-area {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
}

.header-nav {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  flex-wrap: wrap;
}

.header-nav-button {
  height: 34px;
  padding: 0 12px;
  border-radius: 10px;
  border: 1px solid #d7dde5;
  background: #ffffff;
  color: #445261;
  font-size: 13px;
  cursor: pointer;
  transition: all 0.2s ease;
}

.header-nav-button:hover,
.header-nav-button.active {
  border-color: #1f5ea8;
  color: #1f5ea8;
  background: #f4f8fc;
}

.header-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}

.menu-link {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 34px;
  padding: 0 12px;
  border-radius: 999px;
  border: 1px solid #d7dde5;
  background: #ffffff;
  color: #445261;
  cursor: pointer;
  user-select: none;
}

.header-status-chip {
  padding: 6px 10px;
  border-radius: 10px;
  background: #eef3f8;
  color: #425466;
  font-size: 12px;
  font-weight: 500;
  max-width: 240px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.time {
  font-family: Consolas, monospace;
  color: #697586;
  font-size: 12px;
}

.panel {
  display: flex;
  flex-direction: column;
  gap: 12px;
  min-height: 0;
}

.left-panel,
.right-panel {
  width: auto;
}

.panel-block {
  background: #ffffff;
  border-radius: 16px;
  border: 1px solid #dde3ea;
  padding: 16px;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.flex-grow {
  flex: 1;
  min-height: 0;
}

.panel-column-layout {
  display: flex;
  flex-direction: column;
  gap: 12px;
  height: 100%;
}

.split-panel {
  flex: 1;
  min-height: 0;
}

.workspace-center {
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.workspace-map-card {
  display: flex;
  flex-direction: column;
  min-height: 0;
  height: 100%;
  padding: 16px;
  background: #ffffff;
  border-radius: 16px;
  border: 1px solid #dde3ea;
}

.workspace-card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 12px;
}

.workspace-card-header h2 {
  margin: 0;
  font-size: 18px;
  font-weight: 700;
  color: #16212b;
}

.workspace-caption {
  margin: 4px 0 0;
  font-size: 12px;
  color: #6b7785;
}

.workspace-card-meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  justify-content: flex-end;
}

.workspace-meta-item {
  display: inline-flex;
  align-items: center;
  padding: 6px 10px;
  border-radius: 999px;
  background: #f3f5f7;
  color: #546170;
  font-size: 12px;
}

.map-center {
  position: relative;
  flex: 1;
  min-height: 460px;
  border: 1px solid #dde3ea;
  border-radius: 14px;
  overflow: hidden;
  background: #eef2f5;
}

.map-center .leaflet-container {
  width: 100%;
  height: 100%;
  background: #eef2f5;
}

.map-controller {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 0 0;
  margin-top: 12px;
  flex-wrap: wrap;
}

.control-group,
.history-row,
.section-toolbar {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}

.compact-row {
  justify-content: space-between;
  flex-wrap: wrap;
}

.control-label {
  font-size: 12px;
  color: #697586;
  font-weight: 500;
}

.divider-v {
  width: 1px;
  align-self: stretch;
  background: #dde3ea;
}

h3 {
  margin: 0;
  font-size: 15px;
  color: #16212b;
  letter-spacing: 0;
}

.block-header-flex,
.panel-header-row,
.status-row,
.value-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.stat-grid-simple {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
  margin-top: 14px;
}

.stat-row-group {
  display: contents;
}

.stat-item {
  min-width: 0;
  padding: 14px;
  border-radius: 12px;
  background: #f8fafb;
  border: 1px solid #e6ebf0;
}

.cursor-pointer {
  cursor: pointer;
  transition: border-color 0.2s ease, transform 0.2s ease, background 0.2s ease;
}

.cursor-pointer:hover {
  transform: translateY(-1px);
  border-color: #cbd4dd;
  background: #f3f7fa;
}
.label,
.detail-label,
.list-sub-text {
  font-size: 12px;
  color: #6b7785;
}

.value,
strong,
.dev-name,
.warn-type {
  color: #16212b;
}

.value {
  font-family: Consolas, monospace;
  font-size: 26px;
  font-weight: 700;
}

.num-green { color: #67c23a; }
.num-red { color: #f56c6c; }
.num-blue { color: #1f5ea8; }
.num-orange { color: #f29b2f; }
.bg-green { background: #67c23a; }
.bg-red { background: #f56c6c; }
.bg-blue { background: #1f5ea8; }
.bg-orange { background: #f29b2f; }

.mini-bar {
  width: 24px;
  height: 3px;
  margin-top: 10px;
  border-radius: 4px;
}

.signal-box {
  display: none;
}

.signal-bar {
  width: 4px;
  background: #1f5ea8;
  border-radius: 999px;
  animation: signal-blink 1.4s infinite ease-in-out;
}

.b1 { height: 7px; }
.b2 { height: 12px; animation-delay: 0.18s; }
.b3 { height: 16px; animation-delay: 0.35s; }

.history-controls {
  margin-top: 14px;
  padding: 12px;
  border-radius: 12px;
  background: #f8fafb;
  border: 1px solid #e6ebf0;
}

.monitor-container {
  flex: 1;
  min-height: 0;
  margin-top: 14px;
}

.chart-shell,
.panel-table-shell {
  height: 100%;
  border-radius: 12px;
  background: #f8fafb;
  border: 1px solid #e6ebf0;
  overflow: hidden;
}

.trend-chart {
  width: 100%;
  height: 100%;
  min-height: 320px;
}

.list-container,
.command-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
  overflow-y: auto;
  min-height: 0;
}

.list-item,
.detail-card,
.report-kpi,
.command-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  padding: 12px 14px;
  border-radius: 12px;
  background: #f8fafb;
  border: 1px solid #e6ebf0;
}

.list-item-left,
.detail-stack,
.report-stack,
.report-export-box,
.user-form-box,
.device-detail-card {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.warning-item-border {
  border-left: 3px solid #f29b2f;
}

.two-col {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.empty-tip {
  padding: 18px 0;
  text-align: center;
  color: #7c8896;
  font-size: 13px;
}

.detail-row {
  display: flex;
  gap: 10px;
  align-items: flex-start;
}

.d-label {
  width: 88px;
  color: #6b7785;
}

.d-value {
  flex: 1;
  color: #16212b;
}

.bold { font-weight: 700; }
.mono { font-family: Consolas, monospace; }

.dialog-action-row,
.user-dialog-shell {
  display: flex;
  gap: 12px;
}

.user-dialog-shell {
  align-items: flex-start;
}

.user-form-box {
  width: 280px;
  flex-shrink: 0;
}

.user-form-title {
  font-size: 14px;
  font-weight: 700;
  color: #1d3249;
}

.map-popup-card {
  min-width: 180px;
  color: #16212b;
}

.popup-title {
  font-size: 14px;
  font-weight: 700;
  margin-bottom: 8px;
}

.popup-row {
  margin-bottom: 4px;
  color: #546170;
  font-size: 12px;
}

.custom-div-icon {
  background: transparent;
  border: none;
}

.custom-marker {
  position: relative;
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: 2px solid #fff;
  box-shadow: 0 2px 8px rgba(15, 23, 42, 0.18);
}

.marker-online {
  background: #67c23a;
}

.marker-offline {
  background: #909399;
}

.custom-marker .pulse {
  display: none;
}

.marker-count {
  position: absolute;
  right: -8px;
  top: -8px;
  min-width: 16px;
  height: 16px;
  border-radius: 999px;
  background: #f56c6c;
  color: #fff;
  font-size: 10px;
  line-height: 16px;
  text-align: center;
  font-weight: 700;
}

@media (max-width: 1400px) {
  .main-content {
    grid-template-columns: 300px minmax(0, 1fr) 320px;
  }
}

@media (max-width: 1200px) {
  .main-content {
    grid-template-columns: 1fr;
    overflow: auto;
  }

  .workspace-card-header {
    flex-direction: column;
    align-items: flex-start;
  }

  .map-center {
    min-height: 380px;
  }

  .status-area {
    flex-wrap: wrap;
    justify-content: flex-end;
  }

  .header-actions {
    flex-wrap: wrap;
    justify-content: flex-end;
  }
}

@media (max-width: 768px) {
  .top-header {
    padding: 12px 16px;
    align-items: flex-start;
    gap: 12px;
    flex-direction: column;
  }

  .main-content {
    padding: 12px;
    gap: 12px;
  }

  .stat-grid-simple {
    grid-template-columns: 1fr;
  }

  .two-col {
    grid-template-columns: 1fr;
  }
}
</style>



