<template>
  <div class="logo-area">
    <div class="custom-logo" aria-hidden="true">
      <svg width="42" height="42" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <linearGradient id="brandWater" x1="16" y1="10" x2="84" y2="86" gradientUnits="userSpaceOnUse">
            <stop stop-color="#2f9bff" />
            <stop offset="1" stop-color="#0f3f7f" />
          </linearGradient>
          <linearGradient id="brandMud" x1="30" y1="34" x2="72" y2="76" gradientUnits="userSpaceOnUse">
            <stop stop-color="#8a6a46" />
            <stop offset="1" stop-color="#b88a57" />
          </linearGradient>
        </defs>
        <circle cx="50" cy="50" r="42" fill="url(#brandWater)" />
        <path d="M20 62C30 56 40 58 48 66C54 72 62 74 80 70" stroke="#dff2ff" stroke-width="6" stroke-linecap="round" />
        <path d="M22 70C34 64 46 66 56 74" stroke="#ffffff" stroke-opacity="0.9" stroke-width="4" stroke-linecap="round" />
        <path d="M32 34L48 58L42 58L58 84L52 84L66 62L60 62L74 34H32Z" fill="url(#brandMud)" fill-opacity="0.95" />
      </svg>
    </div>
    <div>
      <h1 class="title">{{ BRAND.productName }}</h1>
      <p class="title-sub">{{ BRAND.tagline }}</p>
    </div>
  </div>
</template>

<script setup>
import { BRAND } from '../../../config/brand'
</script>
