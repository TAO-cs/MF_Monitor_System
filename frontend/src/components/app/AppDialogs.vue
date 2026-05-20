<template>
  <el-dialog v-model="showDeviceDialog" title="设备列表" width="72%" align-center>
    <el-table :data="allDevices" height="420" stripe @row-click="openDeviceDetail">
      <el-table-column prop="aibox_id" label="Aibox" width="100" />
      <el-table-column prop="cam_id" label="Cam" width="100" />
      <el-table-column prop="device_name" label="设备名称" min-width="160" />
      <el-table-column prop="device_type" label="类型" width="110" />
      <el-table-column label="部署位置" min-width="180"><template #default="scope">{{ scope.row.location?.location || '未登记' }}</template></el-table-column>
      <el-table-column label="状态" width="90"><template #default="scope"><el-tag :type="scope.row.status?.online_status === 'on' ? 'success' : 'info'" size="small">{{ scope.row.status?.online_status === 'on' ? '在线' : '离线' }}</el-tag></template></el-table-column>
    </el-table>
  </el-dialog>

  <el-dialog v-model="showSingleDeviceDialog" title="设备详情" width="480px" align-center>
    <div v-if="selectedDevice" class="device-detail-card">
      <div class="detail-row"><span class="d-label">设备名称</span><span class="d-value bold">{{ selectedDevice.device_name || (selectedDevice.aibox_id + '-' + selectedDevice.cam_id) }}</span></div>
      <div class="detail-row"><span class="d-label">设备编号</span><span class="d-value mono">{{ selectedDevice.aibox_id }} / {{ selectedDevice.cam_id }}</span></div>
      <div class="detail-row"><span class="d-label">设备类型</span><span class="d-value">{{ selectedDevice.device_type || '未登记' }}</span></div>
      <div class="detail-row"><span class="d-label">部署位置</span><span class="d-value">{{ selectedDevice.location?.location || '未登记' }}</span></div>
      <div class="detail-row"><span class="d-label">当前状态</span><span class="d-value">{{ selectedDevice.status?.online_status === 'on' ? '在线' : '离线' }}</span></div>
      <div class="detail-row"><span class="d-label">控制权限</span><span class="d-value">配置下发: {{ selectedDevice.allow_config_push ? '允许' : '禁止' }} / 远程控制: {{ selectedDevice.allow_remote_control ? '允许' : '禁止' }}</span></div>
      <div class="dialog-action-row">
        <el-button v-if="isAdmin" size="small" @click="toggleDeviceEnabled(selectedDevice)">{{ selectedDevice.enabled ? '停用设备' : '启用设备' }}</el-button>
        <el-button v-if="canOperate && selectedDevice.allow_config_push" size="small" type="primary" @click="openConfigDialog(selectedDevice)">下发配置</el-button>
      </div>
    </div>
  </el-dialog>

  <el-dialog v-model="showWarningDetailDialog" title="告警详情" width="520px" align-center>
    <div v-if="selectedAlarm" class="device-detail-card">
      <div class="detail-row"><span class="d-label">规则编码</span><span class="d-value bold">{{ selectedAlarm.rule_code }}</span></div>
      <div class="detail-row"><span class="d-label">事件类型</span><span class="d-value">{{ selectedAlarm.event_type }}</span></div>
      <div class="detail-row"><span class="d-label">告警等级</span><span class="d-value">{{ selectedAlarm.severity }}</span></div>
      <div class="detail-row"><span class="d-label">当前状态</span><span class="d-value">{{ selectedAlarm.status }}</span></div>
      <div class="detail-row"><span class="d-label">触发时间</span><span class="d-value mono">{{ formatTime(selectedAlarm.triggered_at) }}</span></div>
      <div class="detail-row"><span class="d-label">设备编号</span><span class="d-value mono">{{ selectedAlarm.aibox_id }} / {{ selectedAlarm.cam_id }}</span></div>
      <div class="dialog-action-row" v-if="canOperate && selectedAlarm.status !== 'closed'"><el-button size="small" @click="ackAlarm(selectedAlarm)">确认告警</el-button><el-button size="small" type="primary" @click="closeAlarm(selectedAlarm)">关闭告警</el-button></div>
    </div>
  </el-dialog>

  <el-dialog v-model="showReportDialog" title="报表导出" width="460px" align-center>
    <div class="report-export-box">
      <div class="detail-row"><span class="d-label">统计窗口</span><span class="d-value">最近 {{ reportWindowHours }} 小时</span></div>
      <el-slider v-model="reportWindowHours" :min="6" :max="168" :step="6" show-stops />
      <div class="detail-row"><span class="d-label">导出内容</span><span class="d-value">设备状态、告警统计、识别记录与流速记录汇总。</span></div>
      <el-button type="primary" style="width:100%" @click="downloadReportCsv">导出 CSV 报表</el-button>
    </div>
  </el-dialog>

  <el-dialog v-model="showConfigPushDialog" title="设备配置下发" width="520px" align-center>
    <el-form label-width="100px">
      <el-form-item label="目标设备"><span>{{ configTargetDeviceLabel }}</span></el-form-item>
      <el-form-item label="配置名称"><el-input v-model="configForm.config_name" /></el-form-item>
      <el-form-item label="配置内容"><el-input v-model="configForm.payload_text" type="textarea" :rows="8" /></el-form-item>
      <el-form-item label="QoS"><el-input-number v-model="configForm.qos" :min="0" :max="2" /></el-form-item>
      <el-form-item label="Retain"><el-switch v-model="configForm.retain" /></el-form-item>
    </el-form>
    <template #footer><el-button @click="showConfigPushDialog = false">取消</el-button><el-button type="primary" :loading="submittingConfig" @click="submitConfigPush">确认下发</el-button></template>
  </el-dialog>

  <el-dialog v-model="showUserManageDialog" title="用户管理" width="760px" align-center>
    <div class="user-dialog-shell">
      <el-table :data="platformUsers" height="260" stripe>
        <el-table-column prop="display_name" label="显示名称" min-width="120" />
        <el-table-column prop="username" label="用户名" min-width="120" />
        <el-table-column prop="role_label" label="角色" width="120" />
        <el-table-column label="状态" width="90"><template #default="scope"><el-tag :type="scope.row.enabled ? 'success' : 'info'" size="small">{{ scope.row.enabled ? '启用' : '停用' }}</el-tag></template></el-table-column>
      </el-table>
      <div class="user-form-box">
        <div class="user-form-title">新增平台用户</div>
        <el-form label-width="90px">
          <el-form-item label="用户名"><el-input v-model="userForm.username" /></el-form-item>
          <el-form-item label="显示名称"><el-input v-model="userForm.display_name" /></el-form-item>
          <el-form-item label="登录密码"><el-input v-model="userForm.password" show-password /></el-form-item>
          <el-form-item label="角色"><el-select v-model="userForm.role" style="width: 100%"><el-option label="管理员" value="admin" /><el-option label="运维人员" value="operator" /><el-option label="只读用户" value="viewer" /></el-select></el-form-item>
          <el-form-item label="启用"><el-switch v-model="userForm.enabled" /></el-form-item>
          <el-button type="primary" style="width:100%" :loading="submittingUser" @click="createPlatformUser">创建用户</el-button>
        </el-form>
      </div>
    </div>
  </el-dialog>
</template>

<script setup>
const props = defineProps({ bindings: { type: Object, required: true } })
const { showDeviceDialog, allDevices, openDeviceDetail, showSingleDeviceDialog, selectedDevice, isAdmin, canOperate, toggleDeviceEnabled, openConfigDialog, showWarningDetailDialog, selectedAlarm, formatTime, ackAlarm, closeAlarm, showReportDialog, reportWindowHours, downloadReportCsv, showConfigPushDialog, configForm, submittingConfig, submitConfigPush, configTargetDeviceLabel, showUserManageDialog, platformUsers, userForm, submittingUser, createPlatformUser } = props.bindings
</script>
