<template>
  <el-dialog v-model="showReportDialog" title="📄 监测周报归档" width="600px" align-center append-to-body>
    <div v-loading="reportLoading" style="min-height: 200px">
      <el-table :data="reportList" style="width: 100%" stripe height="400">
        <el-table-column prop="name" label="周报名称">
          <template #default="scope">
            <el-icon style="vertical-align: middle; margin-right: 5px; color: #409eff"><Document /></el-icon>
            <span style="font-weight: 500">{{ formatReportName(scope.row.name) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="120" align="center">
          <template #default="scope">
            <el-button link type="primary" size="small" @click="viewReport(scope.row.name)">
              在线查看
            </el-button>
          </template>
        </el-table-column>
      </el-table>
      <div v-if="reportList.length === 0 && !reportLoading" style="text-align:center; color:#999; padding:20px">
        暂无周报文件
      </div>
    </div>
  </el-dialog>

  <el-dialog v-model="showExportDialog" title="💾 原始数据导出" width="500px" align-center append-to-body>
    <el-form label-width="100px">
      <el-alert
        title="提示：云端仅保留最近7天数据，更早数据已归档至本地冷存储。"
        type="info"
        show-icon
        :closable="false"
        style="margin-bottom: 20px"
      />

      <el-form-item label="数据类型">
        <el-radio-group v-model="exportForm.type">
          <el-radio-button label="MEMS">MEMS</el-radio-button>
          <el-radio-button label="GNSS">GNSS</el-radio-button>
          <el-radio-button label="Fusion">融合数据</el-radio-button>
        </el-radio-group>
      </el-form-item>

      <el-form-item label="选择设备">
        <el-select
          v-model="exportForm.id"
          placeholder="请先选择上方类型，再选择设备"
          filterable
          style="width: 100%"
          no-data-text="该类型下暂无设备"
        >
          <el-option
            v-for="item in filteredExportDevices"
            :key="item.id"
            :label="item.id + ' (' + (item.locationName || '未知') + ')'"
            :value="item.id"
          />
        </el-select>
      </el-form-item>

      <el-form-item label="时间范围">
        <el-date-picker
          v-model="exportForm.dateRange"
          type="daterange"
          range-separator="至"
          start-placeholder="开始日期"
          end-placeholder="结束日期"
          value-format="YYYY-MM-DD"
          :disabled-date="disabledExportDate"
          style="width: 100%"
        />
      </el-form-item>
    </el-form>

    <template #footer>
      <span class="dialog-footer">
        <el-button @click="showExportDialog = false">取消</el-button>
        <el-button type="primary" :loading="isExporting" @click="handleExport">
          <el-icon class="el-icon--left"><Download /></el-icon> 开始下载
        </el-button>
      </span>
    </template>
  </el-dialog>
</template>

<script setup>
import { Document, Download } from '@element-plus/icons-vue';

const props = defineProps({
  bindings: { type: Object, required: true }
});

const {
  showReportDialog,
  reportLoading,
  reportList,
  formatReportName,
  viewReport,
  showExportDialog,
  exportForm,
  filteredExportDevices,
  disabledExportDate,
  isExporting,
  handleExport
} = props.bindings;
</script>
