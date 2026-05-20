<template>
  <div class="control-group">
    <span class="control-label">设备筛选</span>
    <el-select v-model="mapDeviceFilter" size="small" style="width: 120px">
      <el-option label="全部设备" value="all" />
      <el-option label="在线设备" value="on" />
      <el-option label="离线设备" value="off" />
      <el-option label="告警设备" value="alarm" />
    </el-select>
    <el-button size="small" plain @click="resetMapView">重置视图</el-button>
  </div>
</template>

<script setup>
const props = defineProps({ bindings: { type: Object, required: true } })
const { mapDeviceFilter, resetMapView } = props.bindings
</script>
