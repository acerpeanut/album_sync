const kDefaultBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: '', // 留空，避免将真实地址写入代码库
);
const kDefaultUsername = String.fromEnvironment('USERNAME', defaultValue: '');
const kDefaultPassword = String.fromEnvironment('PASSWORD', defaultValue: '');
const kAutoSetup = bool.fromEnvironment('AUTO_SETUP', defaultValue: false);
const kAutoUpload = bool.fromEnvironment('AUTO_UPLOAD', defaultValue: false);

// 调试/排障相关
const kVerboseLog = bool.fromEnvironment('VERBOSE_LOG', defaultValue: true);
const kDryRun = bool.fromEnvironment('DRY_RUN', defaultValue: false); // 仅计划与远端检查，不执行PUT
