Windows 腾讯云服务器 API取数测试部署说明

一、说明
本目录适用于 Windows 云服务器进行 API 取数测试。
本次部署不走 Linux Docker 容器路线，而是采用：
1. Windows 原生 MySQL
2. Windows 原生 Python + Uvicorn
3. Windows 版 Nginx 反向代理 HTTPS

二、云服务器需要下载的软件
1. Python 3.12 x64
2. MySQL 8.0 Community Server x64
3. nginx Windows 版

三、建议目录
1. 项目目录：D:\mf_api_test
2. MySQL 安装目录：D:\MySQL\mysql-8.0
3. nginx 解压目录：D:\nginx

四、部署大致步骤
1. 将整个 API取数测试 文件夹上传到 D:\mf_api_test
2. 安装 Python
3. 安装 MySQL
4. 用 sql\init.sql 初始化数据库
5. 修改 .env.api-test
6. 运行 start_backend_windows.ps1 启动后端
7. 配置并启动 nginx
8. 放行 80 和 443 端口

五、重要提醒
1. .env.api-test 中 DB_HOST 应改成 127.0.0.1
2. .env.api-test 中 DB_PORT 应改成 3306
3. API_KEY、数据库密码、管理员密码都必须修改
4. 当前 server.crt / server.key 可用于测试，正式环境建议替换为正式证书
