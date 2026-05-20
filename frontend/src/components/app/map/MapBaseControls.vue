<template>
  <div class="control-group">
    <span class="control-label">底图模式</span>
    <el-radio-group v-model="mapMode" size="small" @change="setMapMode">
      <el-radio-button label="satellite">卫星</el-radio-button>
      <el-radio-button label="street">街道</el-radio-button>
    </el-radio-group>
  </div>
</template>

<script setup>
const props = defineProps({ bindings: { type: Object, required: true } })
const { mapMode, setMapMode } = props.bindings
</script>
