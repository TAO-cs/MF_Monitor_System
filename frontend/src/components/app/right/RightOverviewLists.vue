<template>
  <div class="panel-column-layout">
    <div class="panel-block split-panel">
      <div class="panel-header-row"><h3>{{ upperTitle }}</h3></div>

      <div v-if="activeModule === 'overview' || activeModule === 'alarms'" class="list-container">
        <div
          v-for="item in latestAlarms"
          :key="item.id"
          class="list-item cursor-pointer warning-item-border"
          @click="openAlarmDetail(item)"
        >
          <div class="list-item-left">
            <div class="warn-row-top">
              <el-tag :type="severityTag(item.severity)" size="small" effect="dark">
                {{ severityText(item.severity) }}
              </el-tag>
              <span class="warn-type">{{ item.rule_code }}</span>
            </div>
            <span class="list-sub-text">{{ item.aibox_id }} / {{ item.cam_id }}</span>
            <span class="list-sub-text">{{ formatTime(item.triggered_at) }}</span>
          </div>
          <div class="list-item-right">
            <el-tag size="small" type="info" effect="plain">{{ item.status }}</el-tag>
          </div>
        </div>
        <div v-if="latestAlarms.length === 0" class="empty-tip">{{ labels.noAlarms }}</div>
      </div>

      <div v-else-if="activeModule === 'devices'" class="detail-stack">
        <template v-if="selectedDevice">
          <div class="detail-card">
            <span class="detail-label">{{ labels.deviceName }}</span>
            <strong>{{ selectedDevice.device_name || (selectedDevice.aibox_id + '-' + selectedDevice.cam_id) }}</strong>
          </div>
          <div class="detail-card two-col">
            <div>
              <span class="detail-label">Aibox</span>
              <strong>{{ selectedDevice.aibox_id }}</strong>
            </div>
            <div>
              <span class="detail-label">Cam</span>
              <strong>{{ selectedDevice.cam_id }}</strong>
            </div>
          </div>
          <div class="detail-card">
            <span class="detail-label">{{ labels.location }}</span>
            <strong>{{ selectedDevice.location?.location || labels.notRegistered }}</strong>
          </div>
          <div class="detail-card">
            <span class="detail-label">{{ labels.groups }}</span>
            <strong>{{ groupText(selectedDevice) }}</strong>
          </div>
          <div class="detail-card two-col">
            <div>
              <span class="detail-label">{{ labels.deviceState }}</span>
              <strong>{{ selectedDevice.status?.online_status === 'on' ? labels.online : labels.offline }}</strong>
            </div>
            <div>
              <span class="detail-label">{{ labels.latestCommand }}</span>
              <strong>{{ latestCommandText }}</strong>
            </div>
          </div>
        </template>
        <div v-else class="empty-tip">{{ labels.selectDeviceHint }}</div>
      </div>

      <div v-else-if="activeModule === 'reports'" class="list-container">
        <div v-for="item in hotspotRules" :key="item.rule_code" class="list-item">
          <div class="list-item-left">
            <span class="dev-name">{{ item.rule_code }}</span>
            <span class="list-sub-text">{{ labels.hotspotRuleDesc }}</span>
          </div>
          <div class="list-item-right"><strong>{{ item.count }}</strong></div>
        </div>
        <div v-if="hotspotRules.length === 0" class="empty-tip">{{ labels.noHotspots }}</div>
      </div>

      <div v-else class="list-container">
        <div v-for="item in platformUsers" :key="item.username" class="list-item">
          <div class="list-item-left">
            <span class="dev-name">{{ item.display_name }}</span>
            <span class="list-sub-text">{{ item.username }}</span>
          </div>
          <div class="list-item-right">
            <el-tag size="small" :type="item.enabled ? 'success' : 'info'">{{ item.role_label }}</el-tag>
          </div>
        </div>
        <div v-if="platformUsers.length === 0" class="empty-tip">{{ labels.noUsers }}</div>
      </div>
    </div>

    <div class="panel-block split-panel">
      <div class="panel-header-row"><h3>{{ lowerTitle }}</h3></div>

      <div v-if="activeModule === 'overview' || activeModule === 'devices'" class="detail-stack">
        <div v-if="selectedDevice" class="evidence-card">
          <div class="evidence-card-header">
            <div>
              <div class="video-card-title">{{ labels.evidenceWindow }}</div>
              <div class="evidence-subtitle">{{ selectedDevice.device_name || (selectedDevice.aibox_id + '-' + selectedDevice.cam_id) }}</div>
            </div>
            <a
              v-if="latestEvidenceUrl"
              class="evidence-link"
              :href="latestEvidenceUrl"
              target="_blank"
              rel="noopener noreferrer"
            >
              {{ labels.openOriginal }}
            </a>
          </div>

          <a
            v-if="latestEvidenceUrl"
            class="evidence-hero-link"
            :href="latestEvidenceUrl"
            target="_blank"
            rel="noopener noreferrer"
          >
            <img :src="latestEvidenceUrl" :alt="labels.evidenceImageAlt" class="evidence-hero-image" />
          </a>
          <div v-else class="video-empty evidence-empty">{{ labels.noEvidenceImage }}</div>

          <div class="detail-card recent-records-card">
            <span class="detail-label">{{ labels.recentRecords }}</span>
            <div class="record-list">
              <div
                v-for="item in recentClassificationRecords"
                :key="item.id || item.disaster_id || `${item.timestamp}-${item.disaster_type}`"
                class="record-item"
              >
                <div class="record-header">
                  <strong>{{ item.disaster_type || 'unknown' }}</strong>
                  <el-tag size="small" type="danger">{{ formatConfidence(item.confidence) }}</el-tag>
                </div>
                <div class="record-meta">{{ formatTime(item.timestamp) }}</div>
                <div v-if="item.image_path" class="record-path">
                  {{ labels.imagePath }}{{ item.image_path }}
                </div>
                <a
                  v-if="resolveImageUrl(item.image_path)"
                  :href="resolveImageUrl(item.image_path)"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="record-preview-link"
                >
                  <img
                    :src="resolveImageUrl(item.image_path)"
                    :alt="labels.evidenceImageAlt"
                    class="record-preview"
                  />
                </a>
              </div>
              <div v-if="recentClassificationRecords.length === 0" class="empty-tip">{{ labels.noRecords }}</div>
            </div>
          </div>
        </div>

        <div v-else class="video-card waiting-card">
          <div class="video-card-title">{{ labels.evidenceWindow }}</div>
          <div class="video-empty">{{ labels.selectDeviceForMedia }}</div>
        </div>
      </div>

      <div v-else-if="activeModule === 'alarms'" class="detail-stack">
        <template v-if="selectedAlarm">
          <div class="detail-card">
            <span class="detail-label">{{ labels.ruleCode }}</span>
            <strong>{{ selectedAlarm.rule_code }}</strong>
          </div>
          <div class="detail-card two-col">
            <div>
              <span class="detail-label">{{ labels.deviceCode }}</span>
              <strong>{{ selectedAlarm.aibox_id }}</strong>
            </div>
            <div>
              <span class="detail-label">{{ labels.camera }}</span>
              <strong>{{ selectedAlarm.cam_id }}</strong>
            </div>
          </div>
          <div class="detail-card">
            <span class="detail-label">{{ labels.status }}</span>
            <strong>{{ selectedAlarm.status }}</strong>
          </div>
          <div class="detail-card">
            <span class="detail-label">{{ labels.sourceRef }}</span>
            <strong>{{ selectedAlarm.source_ref || labels.generatedBySystem }}</strong>
          </div>
        </template>
        <div v-else class="empty-tip">{{ labels.selectAlarmHint }}</div>
      </div>

      <div v-else-if="activeModule === 'reports'" class="list-container">
        <div v-for="item in disasterMix" :key="item.name" class="list-item">
          <div class="list-item-left">
            <span class="dev-name">{{ item.name }}</span>
            <span class="list-sub-text">{{ labels.disasterStats }}</span>
          </div>
          <div class="list-item-right"><strong>{{ item.value }}</strong></div>
        </div>
        <div v-if="disasterMix.length === 0" class="empty-tip">{{ labels.noDisasterData }}</div>
      </div>

      <div v-else class="list-container">
        <div v-for="item in hotspotRules" :key="item.rule_code" class="list-item">
          <div class="list-item-left">
            <span class="dev-name">{{ item.rule_code }}</span>
            <span class="list-sub-text">{{ labels.ruleTriggerCount }}</span>
          </div>
          <div class="list-item-right"><strong>{{ item.count }}</strong></div>
        </div>
        <div v-if="hotspotRules.length === 0" class="empty-tip">{{ labels.noRules }}</div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ bindings: { type: Object, required: true } })
const {
  activeModule,
  latestAlarms,
  selectedDevice,
  selectedAlarm,
  deviceCommands,
  deviceClassificationRecords,
  hotspotRules,
  disasterMix,
  platformUsers,
  openAlarmDetail,
  formatTime,
} = props.bindings

const labels = {
  latestAlarms: '\u6700\u65b0\u544a\u8b66',
  monitorDevices: '\u76d1\u6d4b\u8bbe\u5907',
  currentDevice: '\u5f53\u524d\u8bbe\u5907',
  monitorVideo: '\u4e8b\u4ef6\u8bc1\u636e',
  alarmList: '\u544a\u8b66\u5217\u8868',
  alarmDetail: '\u544a\u8b66\u8be6\u60c5',
  hotspotRules: '\u70ed\u70b9\u89c4\u5219',
  disasterTypes: '\u707e\u5bb3\u7c7b\u522b',
  platformUsers: '\u5e73\u53f0\u7528\u6237',
  rulesSummary: '\u89c4\u5219\u6458\u8981',
  noAlarms: '\u6682\u65e0\u544a\u8b66\u8bb0\u5f55',
  deviceName: '\u8bbe\u5907\u540d\u79f0',
  location: '\u76d1\u6d4b\u5730\u70b9',
  notRegistered: '\u672a\u767b\u8bb0',
  groups: '\u6240\u5c5e\u5206\u7ec4',
  commandHistory: '\u4e0b\u53d1\u8bb0\u5f55',
  noCommands: '\u6682\u65e0\u4e0b\u53d1\u8bb0\u5f55',
  latestCommand: '\u6700\u65b0\u4e0b\u53d1',
  deviceState: '\u5f53\u524d\u72b6\u6001',
  selectDeviceHint: '\u8bf7\u5728\u5de6\u4fa7\u9009\u62e9\u8bbe\u5907\u67e5\u770b\u8be6\u60c5',
  hotspotRuleDesc: '\u9ad8\u9891\u89e6\u53d1\u89c4\u5219',
  noHotspots: '\u6682\u65e0\u70ed\u70b9\u89c4\u5219\u6570\u636e',
  noUsers: '\u6682\u65e0\u5e73\u53f0\u7528\u6237\u6570\u636e',
  notRegisteredLocation: '\u672a\u767b\u8bb0\u4f4d\u7f6e',
  online: '\u5728\u7ebf',
  offline: '\u79bb\u7ebf',
  noDevices: '\u6682\u65e0\u76d1\u6d4b\u8bbe\u5907\u6570\u636e',
  recentRecords: '\u6700\u8fd1\u8bc6\u522b\u8bb0\u5f55',
  imagePath: '\u622a\u56fe\u8def\u5f84\uff1a',
  noRecords: '\u6682\u65e0\u8bc6\u522b\u8bb0\u5f55',
  videoWindow: '\u76d1\u63a7\u89c6\u9891\u7a97\u53e3',
  evidenceWindow: '\u4e8b\u4ef6\u622a\u56fe',
  selectDeviceForMedia: '\u70b9\u51fb\u5de6\u4fa7\u8bbe\u5907\u6216\u5730\u56fe\u6807\u8bb0\u540e\uff0c\u5728\u6b64\u67e5\u770b\u89c6\u9891\u4e0e\u8bc6\u522b\u8bb0\u5f55',
  videoMissing: '\u5f53\u524d\u8bbe\u5907\u672a\u914d\u7f6e\u53ef\u64ad\u653e\u89c6\u9891\u5730\u5740\uff08metadata_json.video_url\uff09',
  noEvidenceImage: '\u8be5\u8bbe\u5907\u8fd8\u6ca1\u6709\u53ef\u9884\u89c8\u7684\u4e8b\u4ef6\u622a\u56fe',
  openOriginal: '\u6253\u5f00\u539f\u56fe',
  evidenceImageAlt: '\u4e8b\u4ef6\u622a\u56fe',
  ruleCode: '\u89c4\u5219\u7f16\u7801',
  deviceCode: '\u8bbe\u5907\u7f16\u53f7',
  camera: '\u6444\u50cf\u5934',
  status: '\u72b6\u6001',
  sourceRef: '\u6765\u6e90\u6807\u8bc6',
  generatedBySystem: '\u7cfb\u7edf\u81ea\u52a8\u751f\u6210',
  selectAlarmHint: '\u8bf7\u9009\u62e9\u544a\u8b66\u67e5\u770b\u8be6\u60c5',
  disasterStats: '\u707e\u5bb3\u7c7b\u522b\u7edf\u8ba1',
  noDisasterData: '\u6682\u65e0\u707e\u5bb3\u7c7b\u522b\u6570\u636e',
  ruleTriggerCount: '\u89c4\u5219\u89e6\u53d1\u6b21\u6570',
  noRules: '\u6682\u65e0\u89c4\u5219\u6570\u636e',
  critical: '\u7d27\u6025',
  high: '\u9ad8',
  medium: '\u4e2d',
  low: '\u4f4e',
  unknown: '\u672a\u77e5',
  ungrouped: '\u672a\u5206\u7ec4',
}

const titleMap = {
  overview: [labels.latestAlarms, labels.monitorDevices],
  devices: [labels.currentDevice, labels.monitorVideo],
  alarms: [labels.alarmList, labels.alarmDetail],
  reports: [labels.hotspotRules, labels.disasterTypes],
  settings: [labels.platformUsers, labels.rulesSummary],
}

const upperTitle = computed(() => titleMap[activeModule.value]?.[0] || '\u6570\u636e\u9762\u677f')
const lowerTitle = computed(() => titleMap[activeModule.value]?.[1] || '\u8be6\u7ec6\u4fe1\u606f')

const recentClassificationRecords = computed(() => {
  const records = deviceClassificationRecords.value || []
  return records.slice(0, 3)
})

const latestEvidenceRecord = computed(() => recentClassificationRecords.value.find((item) => !!resolveImageUrl(item.image_path)) || null)
const latestEvidenceUrl = computed(() => resolveImageUrl(latestEvidenceRecord.value?.image_path))
const latestCommandText = computed(() => {
  const latest = (deviceCommands.value || [])[0]
  return latest?.command_type || labels.noCommands
})

function severityTag(value) {
  if (value === 'critical' || value === 'high') return 'danger'
  if (value === 'medium') return 'warning'
  return 'info'
}

function severityText(value) {
  return (
    {
      critical: labels.critical,
      high: labels.high,
      medium: labels.medium,
      low: labels.low,
    }[value] || value || labels.unknown
  )
}

function groupText(device) {
  const groups = device?.groups || []
  if (!groups.length) return labels.ungrouped
  return groups.map((item) => item.group_name || item.group_code).join(' / ')
}

function formatConfidence(value) {
  const numeric = Number(value)
  if (!Number.isFinite(numeric)) return '-'
  return `${(numeric * 100).toFixed(1)}%`
}

function resolveImageUrl(path) {
  if (typeof path !== 'string' || !path.trim()) return ''
  if (path.startsWith('http://') || path.startsWith('https://')) return path
  if (path.startsWith('/')) return `${window.location.origin}${path}`
  return ''
}
</script>

<style scoped>
.video-card,
.evidence-card {
  border: 1px solid rgba(214, 223, 236, 0.65);
  background: #f7f9fc;
  border-radius: 14px;
  padding: 10px;
}

.waiting-card {
  min-height: 180px;
}

.video-card-title {
  font-size: 13px;
  color: #2a4668;
  font-weight: 600;
  margin-bottom: 8px;
}

.evidence-card {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.video-empty {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 150px;
  border-radius: 10px;
  background: linear-gradient(140deg, #eef5ff, #f9fcff);
  border: 1px dashed #bdd3ec;
  color: #6f8296;
  font-size: 13px;
  text-align: center;
  padding: 0 12px;
}

.compact-list {
  max-height: 220px;
}

.recent-records-card {
  align-items: stretch;
  background: #ffffff;
}

.record-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.record-item {
  padding-top: 8px;
  border-top: 1px dashed rgba(160, 182, 208, 0.45);
}

.record-item:first-child {
  border-top: none;
  padding-top: 0;
}

.record-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.record-meta,
.record-path {
  margin-top: 6px;
  font-size: 12px;
  color: #60758d;
  line-height: 1.5;
  word-break: break-all;
}

.record-preview {
  width: 100%;
  max-height: 180px;
  object-fit: cover;
  margin-top: 8px;
  border-radius: 10px;
  border: 1px solid #d6e3f1;
  background: #f4f8fd;
}

.evidence-card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}

.evidence-subtitle {
  margin-top: 4px;
  font-size: 12px;
  color: #6f8296;
}

.evidence-link,
.evidence-hero-link,
.record-preview-link {
  display: block;
}

.evidence-link {
  color: #1f5ea8;
  font-size: 12px;
  font-weight: 600;
  text-decoration: none;
}

.evidence-link:hover {
  text-decoration: underline;
}

.evidence-hero-image {
  width: 100%;
  height: 220px;
  object-fit: cover;
  border-radius: 12px;
  border: 1px solid #d6e3f1;
  background: #eef4fb;
}

.evidence-empty {
  height: 220px;
}
</style>
