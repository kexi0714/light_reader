# 项目指令

This file provides global context, coding guidelines, and rules for AI assistants (such as Claude Code) operating within this repository. 

## 1. Git Commit Message Guidelines (Strictly Enforced)

Whenever you modify, generate, or refactor code, you **MUST** automatically provide a corresponding Git commit message at the very end of your response, without requiring me to ask for it.

### 1.1 Formatting Rules
Strictly follow the "Conventional Commits" specification:
`<type>(<scope>): <description>`

### 1.2 Allowed Types
- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation only changes
- `style`: Changes that do not affect the meaning of the code (white-space, formatting, etc.)
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `perf`: A code change that improves performance
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to the build process or auxiliary tools and libraries

### 1.3 Scope & Description Requirements
- **Scope**​: Automatically infer a short, lowercase English scope based on the modified directories/modules (e.g., `api`, `router`, `components`). Omit the scope if the change affects the whole project.
- **Description & Body**​:​**MUST be written in Chinese**​. Keep it concise, imperative, and clear (e.g., "新增...", "修复...", "重构...").

### 1.4 Output Format
The generated commit message must be placed in a standalone markdown code block labeled as `text` at the absolute end of your response, so I can copy it easily.

**Example of expected output:**

```text
feat(history): 新增历史记录 localStorage 持久化，支持 7 天过期自动清理
```

```text
fix(canvas): 修复大图缩放后框选坐标偏移问题

使用 getBoundingClientRect() 替代手动计算，正确处理 CSS transform 缩放。
```
