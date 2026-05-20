<template>
  <aside class="panel left-panel">
    <LeftOverviewStats :bindings="bindings" />
    <LeftMonitorContent :bindings="bindings" />
  </aside>
</template>

<script setup>
import LeftOverviewStats from './left/LeftOverviewStats.vue'
import LeftMonitorContent from './left/LeftMonitorContent.vue'

defineProps({
  bindings: { type: Object, required: true },
})
</script>