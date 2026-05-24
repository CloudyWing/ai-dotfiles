import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import pluginVue from 'eslint-plugin-vue';
import prettierConfig from 'eslint-config-prettier';

export default [
    // 基礎規則組合
    js.configs.recommended,
    ...tseslint.configs.recommended,
    ...pluginVue.configs['flat/recommended'],

    // Vue SFC 內的 <script> 使用 TS parser
    {
        files: ['**/*.vue'],
        languageOptions: {
            parserOptions: {
                parser: tseslint.parser
            }
        }
    },

    // 關閉與 Prettier 衝突的格式規則（必須放在所有規則之後）
    prettierConfig,

    // 專案層自訂規則
    {
        rules: {
            // 強制 if/else/for/while 等控制結構使用大括弧
            curly: ['error', 'all']
        }
    }
];
