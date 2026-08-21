#!/usr/bin/env python3
"""把 statusLine 和全部 hook 注册进每个 CLAUDE_CONFIG_DIR 的 settings.json。

事件覆盖是这里最容易出错的地方，所以集中在一处定义：

  UserPromptSubmit                      -> busy   你提交了输入
  Stop                                  -> done   跑完了
  SessionEnd                            -> idle   会话结束
  Notification                          -> hint   闲置 60 秒，不需要你做什么
  PreToolUse(AskUserQuestion|ExitPlanMode)  -> wait 选项询问 / 计划审批
  PostToolUse(AskUserQuestion|ExitPlanMode) -> busy 你答完了，我继续干
  PermissionRequest                     -> wait   权限请求
  SessionStart                          -> init   只写 session 名，不碰状态

SessionStart 那条不是状态，是给跨会话通信用的：它让 state.sh 把这个会话的
name（~/.claude/sessions/<pid>.json 里的那个，也就是 @mention 的地址）写进
pane 的 @claude_session，一开会话就有，不用等你先敲一句话。
它刻意**不**映射成 idle —— /clear 和 resume 也会触发 SessionStart，而 idle 是
能清除粘性 wait 的两个状态之一，那会把「真在等你决策」的信号悄悄抹掉。

后两条是补上去的。最初只挂了 Notification，结果开着 bypass permissions 时
计划审批完全没有信号 —— 窗口显示成绿色「已完成」，比没有状态更糟。

Notification 原先也映射成 wait，但它同时覆盖「需要授权」和「闲置 60 秒」
两种情况，后者根本不需要你做什么。而真要你决策的场合已经被下面两条各自
盖住了，所以它降级成 hint —— 否则一个三天前的闲置提醒会一直挂着最高警报。

PostToolUse 那条是补的：回答 AskUserQuestion 走的是工具结果，**不产生
UserPromptSubmit**。而 wait 是粘性的、只有 busy/idle 能清除，于是你答完之后
整轮都卡在 wait —— 我明明在干活，标签栏却一直显示「在问你」。

用法:
  register.py --binary PATH --state PATH --win PATH [--remove] [--dry-run]
"""
import argparse
import copy
import json
import os
import shutil
import sys
import time

EVENTS = [
    ("UserPromptSubmit", "", "busy"),
    ("Stop", "", "done"),
    ("SessionEnd", "", "idle"),
    ("Notification", "", "hint"),
    ("PreToolUse", "AskUserQuestion|ExitPlanMode", "wait"),
    ("PostToolUse", "AskUserQuestion|ExitPlanMode", "busy"),
    ("PermissionRequest", "", "wait"),
    ("SessionStart", "", "init"),
]


def config_dirs():
    home = os.path.expanduser("~")
    out = []
    for name in sorted(os.listdir(home)):
        if name == ".claude" or name.startswith(".claude-"):
            p = os.path.join(home, name)
            if os.path.isdir(p):
                out.append(p)
    # .claude 排前面，只是为了输出好读
    out.sort(key=lambda p: (os.path.basename(p) != ".claude", p))
    return out


def is_ours(cmd, scripts):
    return any(str(cmd).startswith(s) for s in scripts)


def apply(path, binary, scripts, remove, dry):
    data = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f) or {}
        except Exception as e:
            print("   ✗ 解析失败 %s (%s)" % (path, e))
            return False

    # 改动与否只能靠比对最终结果来判断。下面重建 hook 条目时无法边走边判断
    # ——「先清掉自己的再按需重建」这个做法每次都会动到结构，即使结果一模一样。
    # 早先靠一个 changed 标志，它在重建循环里被无条件置真，于是每次 install
    # 都备份 + 重写一遍 settings.json，攒出几十份内容相同的 .bak。
    original = copy.deepcopy(data)

    if remove:
        if "statusLine" in data:
            del data["statusLine"]
    else:
        want = {"type": "command", "command": binary, "padding": 0}
        if data.get("statusLine") != want:
            data["statusLine"] = want

    hooks = data.get("hooks") or {}

    # 先清掉本项目已有的条目，再按需重建 —— 这样事件表变了也不会留下孤儿
    for event in list(hooks):
        kept = []
        for entry in hooks[event]:
            if not isinstance(entry, dict):
                kept.append(entry)
                continue
            inner = [h for h in entry.get("hooks", [])
                     if not (isinstance(h, dict) and is_ours(h.get("command", ""), scripts))]
            if inner:
                entry["hooks"] = inner
                kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

    if not remove:
        for event, matcher, state in EVENTS:
            entries = hooks.setdefault(event, [])
            for script in scripts:
                entry = {"hooks": [{"type": "command",
                                    "command": "%s %s" % (script, state)}]}
                if matcher:
                    entry["matcher"] = matcher
                entries.append(entry)

    if hooks:
        data["hooks"] = hooks
    elif "hooks" in data:
        del data["hooks"]

    if data == original:
        print("   - %s 已是最新（未改动，不产生备份）" % path)
        return True
    if dry:
        print("   [dry-run] %s" % path)
        return True

    if os.path.exists(path):
        shutil.copy2(path, "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S")))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    print("   ✓ %s" % path)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--win", required=True)
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    scripts = [a.state, a.win]
    dirs = config_dirs()
    if not dirs:
        print("   ✗ 没找到任何 Claude Code 配置目录")
        sys.exit(1)
    ok = True
    for d in dirs:
        ok = apply(os.path.join(d, "settings.json"), a.binary, scripts,
                   a.remove, a.dry_run) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
