@{
    DenyPatterns = @('*PASSWORD*', '*SECRET*', '*_TOKEN', '*CREDENTIALS*', 'NUGET_API_KEY', 'YunXin_*', 'MONEYBOOK_*', 'CLAUDE_CODE_MESSAGING_TOKEN')
    KeepNames = @('GIT_CONFIG_COUNT')
    KeepPatterns = @('GIT_CONFIG_KEY_*', 'GIT_CONFIG_VALUE_*')
}
