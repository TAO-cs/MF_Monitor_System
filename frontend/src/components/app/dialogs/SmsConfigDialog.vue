<template>
  <el-dialog v-model="showSmsConfigDialog" title="📱 短信预警服务配置" width="450px" align-center append-to-body>
    <el-form label-width="120px" :model="smsForm">
      <el-alert
        title="设置预警触发阈值，系统将向指定号码发送短信。"
        type="success"
        :closable="false"
        style="margin-bottom: 20px"
      />

      <el-form-item label="接收手机号">
        <el-input v-model="smsForm.phone" placeholder="请输入11位手机号" clearable />
      </el-form-item>

      <el-form-item label="最大震中距">
        <el-input-number v-model="smsForm.max_distance" :min="1" :max="5000" style="width: 140px" />
        <span style="margin-left: 10px; color:#666">公里 (km) within</span>
      </el-form-item>

      <el-form-item label="最小震级">
        <el-input-number v-model="smsForm.min_magnitude" :min="1.0" :max="10.0" :precision="1" :step="0.1" style="width: 140px" />
        <span style="margin-left: 10px; color:#666">级 (M) above</span>
      </el-form-item>

      <div style="font-size: 12px; color: #999; margin-left: 60px; line-height: 1.5">
        * 规则逻辑：当地震发生在 <b>{{ smsForm.max_distance }}公里</b> 范围内，且震级大于等于 <b>M{{ smsForm.min_magnitude }}</b> 时触发。
      </div>
    </el-form>

    <template #footer>
      <span class="dialog-footer">
        <el-button @click="showSmsConfigDialog = false">取消</el-button>
        <el-button type="primary" :loading="isSavingSms" @click="saveSmsConfig">
          保存配置
        </el-button>
      </span>
    </template>
  </el-dialog>
</template>

<script setup>
const props = defineProps({
  bindings: { type: Object, required: true }
});

const { showSmsConfigDialog, smsForm, isSavingSms, saveSmsConfig } = props.bindings;
</script>
