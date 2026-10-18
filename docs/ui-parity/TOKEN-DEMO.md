# 一键令牌演示

运行：`python3 scripts/demo-design-token.py`。

实际将浅色 accent 从 `#3979DE` 改为 `#8157DD`，运行生成器与一致性检查，得到：

```swift
static var accent: Color { color("#8157DD", "#78ACFF") }
```

```typescript
static accent(dark: boolean): string { return dark ? "#78ACFF" : "#8157DD"; }
```

鸿蒙 SVG 图标描边和 Web 控制层 CSS 同次生成。演示结束后恢复原 JSON 并重新生成正式颜色；不把演示配色安装到设备。
这验证了数据源到生成文件的传播，不代表两台设备会自动热更新已安装二进制；设备更新仍需正常构建安装。
