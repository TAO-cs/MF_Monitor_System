<template>
  <div class="map-controller">
    <MapBaseControls :bindings="bindings" />
    <div class="divider-v"></div>
    <MapHazardControls :bindings="bindings" />
  </div>
</template>

<script setup>
import MapBaseControls from './map/MapBaseControls.vue'
import MapHazardControls from './map/MapHazardControls.vue'
defineProps({ bindings: { type: Object, required: true } })
</script>