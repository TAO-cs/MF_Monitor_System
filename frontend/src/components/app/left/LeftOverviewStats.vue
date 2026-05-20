<template>
  <div class="panel-block">
    <div class="block-header-flex">
      <h3>平台概览</h3>
      <span class="label">核心状态</span>
    </div>

    <div class="stat-grid-simple">
      <div class="stat-row-group">
        <div class="stat-item cursor-pointer" @click="changeModule('overview')">
          <span class="label">在线设备</span>
          <div class="value-row"><span class="value num-green">{{ cards.devices_online || 0 }}</span></div>
          <div class="mini-bar bg-green"></div>
        </div>
        <div class="stat-item cursor-pointer" @click="changeModule('alarms')">
          <span class="label">待处理告警</span>
          <div class="value-row"><span class="value num-red">{{ cards.open_alarms || 0 }}</span></div>
          <div class="mini-bar bg-red"></div>
        </div>
      </div>
      <div class="stat-row-group">
        <div class="stat-item cursor-pointer" @click="openDeviceDialog">
          <span class="label">设备总数</span>
          <div class="value-row"><span class="value num-blue">{{ cards.devices_total || 0 }}</span></div>
          <div class="mini-bar bg-blue"></div>
        </div>
        <div class="stat-item cursor-pointer" @click="openReportDialog">
          <span class="label">识别记录</span>
          <div class="value-row"><span class="value num-orange">{{ cards.classification_window || 0 }}</span></div>
          <div class="mini-bar bg-orange"></div>
        </div>
      </div>
    </div>

    <div class="history-controls">
      <div class="status-row">
        <span class="control-label">设备启用率</span>
        <strong>{{ enabledRate }}%</strong>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ bindings: { type: Object, required: true } })
const { cards, changeModule, openDeviceDialog, openReportDialog } = props.bindings

const enabledRate = computed(() => {
  const total = Number(cards.value?.devices_total || 0)
  const enabled = Number(cards.value?.devices_enabled || 0)
  return total ? Math.round((enabled / total) * 100) : 0
})
</script>
