<template>
  <el-dialog v-model="showDeviceTypeDialog" title="🛠️ 平台设备接入概览" width="600px" align-center append-to-body>
    <el-table :data="deviceTypeStats" style="width: 100%" stripe border>
      <el-table-column prop="type" label="设备代码" width="100" />
      <el-table-column prop="name" label="设备类型" width="120" />
      <el-table-column prop="count" label="数量(台)" width="90" align="center" />
      <el-table-column label="功能描述" min-width="180">
        <template #default="scope">
          <div class="type-desc-cell">
            <el-tag size="small" effect="plain">{{ scope.row.disaster }}</el-tag>
            <span class="desc-text">{{ scope.row.func }}</span>
          </div>
        </template>
      </el-table-column>
      <el-table-column prop="dataType" label="数据类型" width="100">
        <template #default="scope">
          <el-tag type="info" size="small">{{ scope.row.dataType }}</el-tag>
        </template>
      </el-table-column>
    </el-table>
  </el-dialog>

  <el-dialog v-model="showDeviceDialog" title="🌐 在线设备列表" width="70%" align-center append-to-body>
    <el-table :data="deviceList" style="width: 100%" height="400" stripe>
      <el-table-column prop="id" label="设备编号" width="120" sortable />

      <el-table-column prop="type" label="设备类型" width="100">
        <template #default="scope">
          {{ getDisplayDeviceType(scope.row) }}
        </template>
      </el-table-column>

      <el-table-column label="部署位置名称" min-width="220">
        <template #default="scope">
          <div style="display: flex; align-items: center; justify-content: space-between; padding-right: 10px;">
            <span>{{ scope.row.locationName || '未命名' }}</span>
            <el-button type="primary" link :icon="Edit" size="small" @click="handleEditLocation(scope.row)">
              修改
            </el-button>
          </div>
        </template>
      </el-table-column>
      <el-table-column label="经纬度坐标" min-width="180">
        <template #default="scope">
          <span class="mono-font">E {{ scope.row.lng }}, N {{ scope.row.lat }}</span>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="100">
        <template #default="scope">
          <el-tag :type="scope.row.status === 'online' ? 'success' : 'info'" size="small">
            {{ scope.row.status === 'online' ? '在线' : '离线' }}
          </el-tag>
        </template>
      </el-table-column>
    </el-table>
  </el-dialog>

  <el-dialog v-model="showEditLocationDialog" title="✏️ 修改布设地点" width="400px" align-center append-to-body>
    <el-form @submit.prevent>
      <el-form-item label="设备编号">
        <el-tag type="info">{{ currentEditDevice?.id }}</el-tag>
        <span v-if="isGnssLinked" style="margin-left: 10px; font-size: 12px; color: #e6a23c">
          (关联设备将同步更新)
        </span>
      </el-form-item>
      <el-form-item label="新地点名称">
        <el-input v-model="newLocationName" placeholder="请输入新的地点名称" clearable @keyup.enter="submitLocationUpdate" />
      </el-form-item>
    </el-form>
    <template #footer>
      <span class="dialog-footer">
        <el-button @click="showEditLocationDialog = false">取消</el-button>
        <el-button type="primary" :loading="isUpdatingLocation" @click="submitLocationUpdate">
          确认修改
        </el-button>
      </span>
    </template>
  </el-dialog>

  <el-dialog v-model="showSingleDeviceDialog" title="ℹ️ 设备详细信息" width="400px" align-center append-to-body>
    <div class="device-detail-card" v-if="currentSelectedDeviceDetail">
      <div class="detail-row">
        <span class="d-label">设备名称：</span>
        <span class="d-value bold">{{ currentSelectedDeviceDetail.id }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">设备类型：</span>
        <span class="d-value">{{ getDisplayDeviceType(currentSelectedDeviceDetail) }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">部署位置：</span>
        <span class="d-value">{{ currentSelectedDeviceDetail.locationName }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">经纬度(°)：</span>
        <span class="d-value mono">E {{ currentSelectedDeviceDetail.lng }}, N {{ currentSelectedDeviceDetail.lat }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">当前状态：</span>
        <el-tag :type="currentSelectedDeviceDetail.status === 'online' ? 'success' : 'info'" size="small">
          {{ currentSelectedDeviceDetail.status === 'online' ? '在线' : '离线' }}
        </el-tag>
      </div>
    </div>
  </el-dialog>

  <el-dialog v-model="showWarningDetailDialog" title="⚠️ 预警事件详情" width="400px" align-center append-to-body>
    <div class="device-detail-card" v-if="currentSelectedWarning">
      <div class="detail-row">
        <span class="d-label">预警类型：</span>
        <span class="d-value bold">{{ currentSelectedWarning.type }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">预警等级：</span>
        <el-tag :type="currentSelectedWarning.level === '高危' ? 'danger' : 'warning'" size="small">{{ currentSelectedWarning.level }}</el-tag>
      </div>
      <div class="detail-row">
        <span class="d-label">发生时间：</span>
        <span class="d-value mono">{{ currentSelectedWarning.time }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">位置坐标：</span>
        <span class="d-value mono">E {{ currentSelectedWarning.lng }}, N {{ currentSelectedWarning.lat }}</span>
      </div>
      <div class="detail-row">
        <span class="d-label">详细描述：</span>
        <span class="d-value">{{ currentSelectedWarning.desc }}</span>
      </div>
    </div>
  </el-dialog>
</template>

<script setup>
import { Edit } from '@element-plus/icons-vue';

const props = defineProps({
  bindings: { type: Object, required: true }
});

const {
  showDeviceTypeDialog,
  deviceTypeStats,
  showDeviceDialog,
  deviceList,
  getDisplayDeviceType,
  handleEditLocation,
  showEditLocationDialog,
  currentEditDevice,
  isGnssLinked,
  newLocationName,
  submitLocationUpdate,
  isUpdatingLocation,
  showSingleDeviceDialog,
  currentSelectedDeviceDetail,
  showWarningDetailDialog,
  currentSelectedWarning
} = props.bindings;
</script>
