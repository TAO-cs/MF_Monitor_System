<template>
  <aside class="panel right-panel">
    <RightOverviewLists :bindings="bindings" />
  </aside>
</template>

<script setup>
import RightOverviewLists from './right/RightOverviewLists.vue'
defineProps({ bindings: { type: Object, required: true } })
</script>