<template>
  <div class="panel-block flex-grow">
    <div class="block-header-flex">
      <h3>{{ moduleTitle }}</h3>
      <el-select v-model="activeModule" size="small" style="width: 132px">
        <el-option v-for="item in moduleOptions" :key="item.value" :label="item.label" :value="item.value" />
      </el-select>
    </div>

    <div class="history-controls">
      <div class="history-row compact-row">
        <span class="control-label">统计窗口</span>
        <el-select v-model="timeWindowHours" size="small" style="width: 90px" @change="reloadWindow">
          <el-option v-for="item in windowOptions" :key="item" :label="item + 'h'" :value="item" />
        </el-select>
        <span class="control-label">聚合粒度</span>
        <el-select v-model="bucketMinutes" size="small" style="width: 90px" @change="reloadWindow">
          <el-option v-for="item in bucketOptions" :key="item" :label="item + 'm'" :value="item" />
        </el-select>
      </div>
    </div>

    <div class="monitor-container">
      <template v-if="activeModule === 'overview'">
        <div class="chart-shell"><div :ref="setTrendChartRef" class="trend-chart"></div></div>
      </template>

      <template v-else-if="activeModule === 'devices'">
        <div class="section-toolbar">
          <el-input v-model="deviceKeyword" size="small" placeholder="搜索设备编号或名称" clearable />
          <el-select v-model="deviceOnlineFilter" size="small" style="width: 110px">
            <el-option label="全部状态" value="all" />
            <el-option label="在线" value="on" />
            <el-option label="离线" value="off" />
          </el-select>
        </div>
        <div class="panel-table-shell">
          <el-table :data="deviceTableRows" height="100%" size="small" @row-click="handleDeviceRowClick">
            <el-table-column prop="aibox_id" label="Aibox" width="95" />
            <el-table-column prop="cam_id" label="Cam" width="95" />
            <el-table-column prop="device_name" label="设备名称" min-width="140" />
            <el-table-column label="状态" width="90">
              <template #default="scope"><el-tag :type="scope.row.status?.online_status === 'on' ? 'success' : 'info'" size="small">{{ scope.row.status?.online_status === 'on' ? '在线' : '离线' }}</el-tag></template>
            </el-table-column>
          </el-table>
        </div>
      </template>

      <template v-else-if="activeModule === 'alarms'">
        <div class="section-toolbar">
          <el-select v-model="alarmSeverityFilter" size="small" style="width: 110px"><el-option label="全部等级" value="all" /><el-option label="高" value="high" /><el-option label="中" value="medium" /><el-option label="低" value="low" /><el-option label="紧急" value="critical" /></el-select>
          <el-select v-model="alarmStatusFilter" size="small" style="width: 110px"><el-option label="全部状态" value="all" /><el-option label="Open" value="open" /><el-option label="Ack" value="ack" /><el-option label="Closed" value="closed" /></el-select>
          <el-select v-model="alarmEventFilter" size="small" style="width: 120px"><el-option label="全部类型" value="all" /><el-option label="识别" value="classification" /><el-option label="流速" value="speed" /><el-option label="设备状态" value="device_status" /></el-select>
        </div>
        <div class="panel-table-shell">
          <el-table :data="alarmTableRows" height="100%" size="small" @row-click="handleAlarmRowClick">
            <el-table-column prop="rule_code" label="规则编码" min-width="150" />
            <el-table-column prop="severity" label="等级" width="90" />
            <el-table-column prop="status" label="状态" width="90" />
            <el-table-column prop="event_type" label="事件类型" width="110" />
          </el-table>
        </div>
      </template>

      <template v-else-if="activeModule === 'reports'">
        <div class="report-stack">
          <div class="report-kpi"><span>流速记录</span><strong>{{ cards.speed_window || 0 }}</strong></div>
          <div class="report-kpi"><span>启用设备</span><strong>{{ cards.devices_enabled || 0 }}</strong></div>
          <div class="report-kpi"><span>停用设备</span><strong>{{ cards.devices_disabled || 0 }}</strong></div>
          <el-button type="primary" plain @click="openReportDialog">导出统计报表</el-button>
        </div>
      </template>

      <template v-else>
        <div class="report-stack">
          <div class="report-kpi"><span>平台用户</span><strong>{{ platformUsers.length }}</strong></div>
          <div class="report-kpi"><span>告警规则</span><strong>{{ alarmRules.length }}</strong></div>
          <el-button type="primary" plain @click="openUserDialog">进入用户管理</el-button>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ bindings: { type: Object, required: true } })
const {
  activeModule,
  moduleOptions,
  timeWindowHours,
  bucketMinutes,
  reloadWindow,
  setTrendChartRef,
  deviceKeyword,
  deviceOnlineFilter,
  filteredDevices,
  handleDeviceRowClick,
  alarmSeverityFilter,
  alarmStatusFilter,
  alarmEventFilter,
  filteredAlarms,
  handleAlarmRowClick,
  cards,
  openReportDialog,
  platformUsers,
  alarmRules,
  openUserDialog,
} = props.bindings

const windowOptions = [6, 12, 24, 48, 72, 168]
const bucketOptions = [15, 30, 60, 120, 360]
const moduleTitle = computed(() => ({
  overview: '监测地点',
  devices: '监测设备',
  alarms: '告警中心',
  reports: '数据报表',
  settings: '系统管理',
}[activeModule.value] || '平台管理'))
const deviceTableRows = computed(() => filteredDevices.value.slice(0, 200))
const alarmTableRows = computed(() => filteredAlarms.value.slice(0, 200))
</script>
