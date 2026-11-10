CREATE DATABASE BPS_ServiceDB;
GO
ALTER DATABASE BPS_ServiceDB SET RECOVERY FULL;
GO
CREATE LOGIN bps_api WITH PASSWORD = 'ChangeMe#123';
GO
USE BPS_ServiceDB;
GO
CREATE USER bps_api FOR LOGIN bps_api;
ALTER ROLE db_owner ADD MEMBER bps_api;  -- temporary for development
GO