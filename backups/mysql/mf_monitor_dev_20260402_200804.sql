-- MySQL dump 10.13  Distrib 8.0.45, for Win64 (x86_64)
--
-- Host: 127.0.0.1    Database: mf_monitor
-- ------------------------------------------------------
-- Server version	8.0.45

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `device_location`
--

DROP TABLE IF EXISTS `device_location`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `device_location` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `aibox_id` varchar(50) NOT NULL,
  `cam_id` varchar(50) NOT NULL,
  `location` varchar(200) NOT NULL,
  `latitude` decimal(10,7) NOT NULL,
  `longitude` decimal(10,7) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_device_location` (`aibox_id`,`cam_id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `device_location`
--

LOCK TABLES `device_location` WRITE;
/*!40000 ALTER TABLE `device_location` DISABLE KEYS */;
INSERT INTO `device_location` VALUES (1,'MF001','CAM001','æµ‹è¯•ç‚¹A',34.0500000,118.0500000,'2026-04-02 09:47:34','2026-04-02 09:47:34');
/*!40000 ALTER TABLE `device_location` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `device_status`
--

DROP TABLE IF EXISTS `device_status`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `device_status` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `aibox_id` varchar(50) NOT NULL,
  `cam_id` varchar(50) NOT NULL,
  `online_status` enum('on','off') NOT NULL,
  `last_update` datetime NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_device_status` (`aibox_id`,`cam_id`),
  KEY `idx_status_update` (`last_update`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `device_status`
--

LOCK TABLES `device_status` WRITE;
/*!40000 ALTER TABLE `device_status` DISABLE KEYS */;
INSERT INTO `device_status` VALUES (1,'MF001','CAM001','on','2026-04-02 19:26:12','2026-04-02 09:47:34','2026-04-02 11:26:12');
/*!40000 ALTER TABLE `device_status` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `disaster_data`
--

DROP TABLE IF EXISTS `disaster_data`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `disaster_data` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `disaster_id` varchar(50) NOT NULL,
  `aibox_id` varchar(50) NOT NULL,
  `cam_id` varchar(50) NOT NULL,
  `disaster_type` enum('flood','mudslide') NOT NULL,
  `timestamp` datetime NOT NULL,
  `confidence` decimal(5,4) NOT NULL,
  `image_path` varchar(255) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_disaster_time` (`timestamp`),
  KEY `idx_disaster_device_time` (`aibox_id`,`cam_id`,`timestamp`),
  KEY `idx_disaster_aibox_time` (`aibox_id`,`timestamp`),
  KEY `idx_disaster_id` (`disaster_id`)
) ENGINE=InnoDB AUTO_INCREMENT=18 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `disaster_data`
--

LOCK TABLES `disaster_data` WRITE;
/*!40000 ALTER TABLE `disaster_data` DISABLE KEYS */;
INSERT INTO `disaster_data` VALUES (1,'20260402_175031_653','MF001','CAM001','flood','2026-04-02 17:50:32',0.8170,'https://storage.server/data/images/MF001/CAM001/1775123431.jpg','2026-04-02 09:50:31'),(2,'20260402_175034_775','MF001','CAM001','flood','2026-04-02 17:50:35',0.8507,'https://storage.server/data/images/MF001/CAM001/1775123434.jpg','2026-04-02 09:50:34'),(3,'20260402_175037_353','MF001','CAM001','mudslide','2026-04-02 17:50:38',0.7907,'https://storage.server/data/images/MF001/CAM001/1775123437.jpg','2026-04-02 09:50:37'),(4,'20260402_175040_233','MF001','CAM001','mudslide','2026-04-02 17:50:41',0.8322,'https://storage.server/data/images/MF001/CAM001/1775123440.jpg','2026-04-02 09:50:39'),(5,'20260402_175043_460','MF001','CAM001','mudslide','2026-04-02 17:50:44',0.8873,'https://storage.server/data/images/MF001/CAM001/1775123443.jpg','2026-04-02 09:50:43'),(6,'20260402_192539_539','MF001','CAM001','flood','2026-04-02 19:25:39',0.8044,'https://storage.server/data/images/MF001/CAM001/1775129139.jpg','2026-04-02 11:25:39'),(7,'20260402_192542_767','MF001','CAM001','flood','2026-04-02 19:25:42',0.7711,'https://storage.server/data/images/MF001/CAM001/1775129142.jpg','2026-04-02 11:25:42'),(8,'20260402_192545_128','MF001','CAM001','mudslide','2026-04-02 19:25:45',0.8180,'https://storage.server/data/images/MF001/CAM001/1775129145.jpg','2026-04-02 11:25:45'),(9,'20260402_192548_224','MF001','CAM001','flood','2026-04-02 19:25:48',0.8054,'https://storage.server/data/images/MF001/CAM001/1775129148.jpg','2026-04-02 11:25:48'),(10,'20260402_192551_541','MF001','CAM001','mudslide','2026-04-02 19:25:51',0.9077,'https://storage.server/data/images/MF001/CAM001/1775129151.jpg','2026-04-02 11:25:51'),(11,'20260402_192554_586','MF001','CAM001','flood','2026-04-02 19:25:54',0.8102,'https://storage.server/data/images/MF001/CAM001/1775129154.jpg','2026-04-02 11:25:54'),(12,'20260402_192557_297','MF001','CAM001','flood','2026-04-02 19:25:57',0.8096,'https://storage.server/data/images/MF001/CAM001/1775129157.jpg','2026-04-02 11:25:57'),(13,'20260402_192600_827','MF001','CAM001','flood','2026-04-02 19:26:00',0.7656,'https://storage.server/data/images/MF001/CAM001/1775129160.jpg','2026-04-02 11:25:59'),(14,'20260402_192603_857','MF001','CAM001','mudslide','2026-04-02 19:26:03',0.8652,'https://storage.server/data/images/MF001/CAM001/1775129163.jpg','2026-04-02 11:26:02'),(15,'20260402_192606_662','MF001','CAM001','flood','2026-04-02 19:26:06',0.9650,'https://storage.server/data/images/MF001/CAM001/1775129166.jpg','2026-04-02 11:26:06'),(16,'20260402_192609_437','MF001','CAM001','flood','2026-04-02 19:26:09',0.7676,'https://storage.server/data/images/MF001/CAM001/1775129169.jpg','2026-04-02 11:26:09'),(17,'20260402_192612_586','MF001','CAM001','mudslide','2026-04-02 19:26:12',0.8749,'https://storage.server/data/images/MF001/CAM001/1775129172.jpg','2026-04-02 11:26:12');
/*!40000 ALTER TABLE `disaster_data` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `speed_data`
--

DROP TABLE IF EXISTS `speed_data`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `speed_data` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `aibox_id` varchar(50) NOT NULL,
  `cam_id` varchar(50) NOT NULL,
  `disaster_type` enum('flood','mudslide') NOT NULL,
  `timestamp` datetime NOT NULL,
  `speed` json NOT NULL COMMENT 'æµé€Ÿå‘é‡æ•°ç»„',
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_speed_time` (`timestamp`),
  KEY `idx_speed_device_time` (`aibox_id`,`cam_id`,`timestamp`),
  KEY `idx_speed_aibox_time` (`aibox_id`,`timestamp`)
) ENGINE=InnoDB AUTO_INCREMENT=18 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `speed_data`
--

LOCK TABLES `speed_data` WRITE;
/*!40000 ALTER TABLE `speed_data` DISABLE KEYS */;
INSERT INTO `speed_data` VALUES (1,'MF001','CAM001','mudslide','2026-04-02 17:50:32','[2.19, 1.72, 1.48, 0.77]','2026-04-02 09:50:31'),(2,'MF001','CAM001','flood','2026-04-02 17:50:35','[2.02, 0.81, 1.15, 1.51]','2026-04-02 09:50:34'),(3,'MF001','CAM001','mudslide','2026-04-02 17:50:38','[1.73, 1.7, 2.36, 1.11]','2026-04-02 09:50:37'),(4,'MF001','CAM001','mudslide','2026-04-02 17:50:41','[1.75, 2.45, 1.8, 1.02]','2026-04-02 09:50:39'),(5,'MF001','CAM001','flood','2026-04-02 17:50:44','[0.77, 0.91, 0.94, 0.69]','2026-04-02 09:50:43'),(6,'MF001','CAM001','mudslide','2026-04-02 19:25:39','[1.98, 1.51, 1.55, 0.96]','2026-04-02 11:25:39'),(7,'MF001','CAM001','flood','2026-04-02 19:25:42','[2.49, 1.08, 1.47, 1.64]','2026-04-02 11:25:42'),(8,'MF001','CAM001','flood','2026-04-02 19:25:45','[1.72, 2.47, 1.66, 1.69]','2026-04-02 11:25:45'),(9,'MF001','CAM001','flood','2026-04-02 19:25:48','[0.87, 1.18, 0.86, 2.31]','2026-04-02 11:25:48'),(10,'MF001','CAM001','flood','2026-04-02 19:25:51','[1.51, 1.94, 1.43, 1.79]','2026-04-02 11:25:51'),(11,'MF001','CAM001','flood','2026-04-02 19:25:54','[1.79, 2.43, 1.82, 1.05]','2026-04-02 11:25:54'),(12,'MF001','CAM001','flood','2026-04-02 19:25:57','[2.39, 0.8, 0.54, 0.6]','2026-04-02 11:25:57'),(13,'MF001','CAM001','mudslide','2026-04-02 19:26:00','[2.45, 1.42, 2.44, 0.9]','2026-04-02 11:25:59'),(14,'MF001','CAM001','flood','2026-04-02 19:26:03','[1.22, 1.54, 2.31, 2.22]','2026-04-02 11:26:02'),(15,'MF001','CAM001','mudslide','2026-04-02 19:26:06','[1.22, 1.07, 1.34, 1.57]','2026-04-02 11:26:06'),(16,'MF001','CAM001','flood','2026-04-02 19:26:09','[0.89, 1.2, 2.08, 2.35]','2026-04-02 11:26:09'),(17,'MF001','CAM001','flood','2026-04-02 19:26:12','[2.03, 1.37, 1.34, 0.54]','2026-04-02 11:26:12');
/*!40000 ALTER TABLE `speed_data` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-04-02 20:08:04
