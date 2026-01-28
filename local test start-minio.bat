@echo off
   set MINIO_ROOT_USER=ВАШ_ЛОГИН_MINIO
   set MINIO_ROOT_PASSWORD=ВАШ_ПАРОЛЬ_MINIO
   C:\MinIO\minio.exe server C:\MinIOBase --address ":9000" --console-address ":9001"