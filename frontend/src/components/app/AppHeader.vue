<template>
  <header class="top-header">
    <AppHeaderBrand />
    <AppHeaderMenus :bindings="bindings" />
  </header>
</template>

<script setup>
import AppHeaderBrand from './header/AppHeaderBrand.vue'
import AppHeaderMenus from './header/AppHeaderMenus.vue'

defineProps({
  bindings: { type: Object, required: true },
})
</script>