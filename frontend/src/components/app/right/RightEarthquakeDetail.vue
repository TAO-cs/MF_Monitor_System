<template>
  <div class="panel-block full-height eq-panel">
    <h3>⚛️ 灾害速报监测</h3>

    <div class="eq-header-card">
      <div class="eq-mag-box" style="background: #f56c6c">
        <span class="mag-label">M</span>
        <span class="mag-val">{{ currentEarthquakeData.mag }}</span>
      </div>
      <div class="eq-base-info">
        <div class="eq-row">
          <el-icon><Timer /></el-icon> {{ currentEarthquakeData.time }}
        </div>
        <div class="eq-row">
          <el-icon><Location /></el-icon> {{ currentEarthquakeData.location }}
        </div>
        <div class="eq-row">
          <el-icon><Odometer /></el-icon>
          震源深度: {{ currentEarthquakeData.depth }}km
        </div>
      </div>
    </div>

    <div class="eq-metrics-grid">
      <div class="metric-box">
        <span class="m-label">平均 PGA (加速度)</span>
        <span class="m-val">{{ currentEarthquakeData.avgPga }} <small>gal</small></span>
        <el-progress :percentage="Math.min(currentEarthquakeData.avgPga / 10, 100)" :show-text="false" color="#f56c6c" />
      </div>
      <div class="metric-box">
        <span class="m-label">平均 PGV (速度)</span>
        <span class="m-val">{{ currentEarthquakeData.avgPgv }} <small>cm/s</small></span>
        <el-progress :percentage="Math.min(currentEarthquakeData.avgPgv * 1, 100)" :show-text="false" color="#e6a23c" />
      </div>
    </div>

    <div class="intensity-list-wrap">
      <h4>监测台站列表 ({{ currentEarthquakeData.stationList.length }}台)</h4>

      <div class="intensity-table">
        <div class="i-row header">
          <span style="flex:1">台站ID</span>
          <span style="width:80px; text-align:center">PGA</span>
          <span style="width:80px; text-align:center">PGV</span>
        </div>

        <div v-for="(item, index) in currentEarthquakeData.stationList" :key="index" class="i-row">
          <span style="flex:1; font-weight:bold; color:#606266; font-family:'Consolas'">{{ item.id }}</span>
          <span style="width:80px; text-align:center; font-family:'Consolas'">{{ item.pga }}</span>
          <span style="width:80px; text-align:center; font-family:'Consolas'">{{ item.pgv }}</span>
        </div>

        <div v-if="currentEarthquakeData.stationList.length === 0" style="text-align:center; padding:20px; color:#999; font-size:12px">
          该事件暂无台站上报数据
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { Timer, Location, Odometer } from '@element-plus/icons-vue';

const props = defineProps({
  bindings: { type: Object, required: true }
});

const { currentEarthquakeData } = props.bindings;
</script>
