<template>
  <div class="login-page">
    <div class="login-card">
      <div class="brand-logo" aria-hidden="true">
        <svg width="46" height="46" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="loginWater" x1="16" y1="10" x2="84" y2="86" gradientUnits="userSpaceOnUse">
              <stop stop-color="#2f9bff" />
              <stop offset="1" stop-color="#0f3f7f" />
            </linearGradient>
            <linearGradient id="loginMud" x1="30" y1="34" x2="72" y2="76" gradientUnits="userSpaceOnUse">
              <stop stop-color="#8a6a46" />
              <stop offset="1" stop-color="#b88a57" />
            </linearGradient>
          </defs>
          <circle cx="50" cy="50" r="42" fill="url(#loginWater)" />
          <path d="M20 62C30 56 40 58 48 66C54 72 62 74 80 70" stroke="#dff2ff" stroke-width="6" stroke-linecap="round" />
          <path d="M22 70C34 64 46 66 56 74" stroke="#ffffff" stroke-opacity="0.9" stroke-width="4" stroke-linecap="round" />
          <path d="M32 34L48 58L42 58L58 84L52 84L66 62L60 62L74 34H32Z" fill="url(#loginMud)" fill-opacity="0.95" />
        </svg>
      </div>

      <h1>{{ BRAND.productName }}</h1>
      <p class="subtitle">{{ BRAND.loginHint }}</p>

      <el-form ref="loginFormRef" :model="loginForm" :rules="loginRules" class="login-form" size="large" @keyup.enter="handleSubmit">
        <el-form-item prop="username">
          <el-input v-model="loginForm.username" placeholder="请输入账号" clearable />
        </el-form-item>
        <el-form-item prop="password">
          <el-input v-model="loginForm.password" type="password" placeholder="请输入密码" show-password />
        </el-form-item>
        <div class="row-actions">
          <el-checkbox v-model="rememberMe">记住我</el-checkbox>
        </div>
        <el-button type="primary" class="submit-btn" :loading="submitting" @click="handleSubmit">登 录</el-button>
      </el-form>

      <div class="footer">{{ BRAND.footerText }}</div>
    </div>
  </div>
</template>

<script setup>
import { reactive, ref } from 'vue'
import { ElNotification } from 'element-plus'
import { BRAND } from '../config/brand'

const props = defineProps({
  onLogin: {
    type: Function,
    required: true,
  },
})

const emit = defineEmits(['login-success'])
const loginFormRef = ref(null)
const submitting = ref(false)
const rememberMe = ref(true)
const loginForm = reactive({
  username: '',
  password: '',
})

const loginRules = {
  username: [{ required: true, message: '请输入账号', trigger: 'blur' }],
  password: [{ required: true, message: '请输入密码', trigger: 'blur' }],
}

function handleSubmit() {
  if (!loginFormRef.value || submitting.value) return
  loginFormRef.value.validate(async (valid) => {
    if (!valid) return
    submitting.value = true
    try {
      const result = await props.onLogin({
        username: loginForm.username.trim(),
        password: loginForm.password,
        remember: rememberMe.value,
      })
      emit('login-success', result)
    } catch (error) {
      ElNotification({
        title: '登录失败',
        message: error.message || '账号或密码错误',
        type: 'error',
      })
    } finally {
      submitting.value = false
    }
  })
}
</script>

<style scoped>
.login-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
  background: #f3f5f7;
}

.login-card {
  width: min(420px, 100%);
  padding: 32px;
  border-radius: 16px;
  border: 1px solid #dde3ea;
  background: #ffffff;
  box-shadow: 0 10px 30px rgba(15, 23, 42, 0.06);
  text-align: center;
}

.brand-logo {
  width: 56px;
  height: 56px;
  margin: 0 auto 12px;
  border-radius: 14px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f3f5f7;
}

h1 {
  margin: 0;
  font-size: 26px;
  color: #16212b;
  font-weight: 700;
}

.subtitle {
  margin: 8px 0 24px;
  color: #6b7785;
  font-size: 13px;
}

.login-form {
  text-align: left;
}

.row-actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin: 2px 0 14px;
  color: #6b7785;
}

.submit-btn {
  width: 100%;
  height: 44px;
  border-radius: 10px;
  font-size: 15px;
}

.footer {
  margin-top: 18px;
  color: #8b96a3;
  font-size: 12px;
}
</style>
