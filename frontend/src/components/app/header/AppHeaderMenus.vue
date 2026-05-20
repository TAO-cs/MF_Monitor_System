<template>
  <div class="status-area">
    <div class="header-nav">
      <button
        v-for="item in moduleOptions"
        :key="item.value"
        type="button"
        class="header-nav-button"
        :class="{ active: activeModule === item.value }"
        @click="changeModule(item.value)"
      >
        {{ item.label }}
      </button>
    </div>

    <div class="header-actions">
      <el-button text @click="quickRefresh">刷新</el-button>
      <el-button text @click="openReportDialog">报表</el-button>
      <el-button v-if="isAdmin" text @click="handleUserCommand('users')">用户</el-button>
      <div class="header-status-chip">{{ statusText }}</div>
      <span class="time">{{ currentTime }}</span>
      <el-dropdown trigger="click" @command="handleUserCommand">
        <span class="menu-link">
          <span>{{ currentUser?.display_name || currentUser?.username || '当前用户' }}</span>
          <el-icon class="el-icon--right"><CaretBottom /></el-icon>
        </span>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item disabled>{{ currentUser?.role_label || activeModuleLabel }}</el-dropdown-item>
            <el-dropdown-item v-if="isAdmin" command="users">用户管理</el-dropdown-item>
            <el-dropdown-item divided command="logout">退出登录</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
    </div>
  </div>
</template>

<script setup>
import { CaretBottom } from '@element-plus/icons-vue'

const props = defineProps({
  bindings: { type: Object, required: true },
})

const {
  currentTime,
  currentUser,
  activeModule,
  activeModuleLabel,
  moduleOptions,
  changeModule,
  openReportDialog,
  handleUserCommand,
  quickRefresh,
  isAdmin,
  statusText,
} = props.bindings
</script>
