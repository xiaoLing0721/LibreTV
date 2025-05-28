#!/bin/bash

# 默认参数
BRANCH="main"
MESSAGE="auto commit"

# 读取参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--branch) BRANCH="$2"; shift ;;
        -m|--message) MESSAGE="$2"; shift ;;
        *) echo "未知参数: $1" ;;
    esac
    shift
done

echo "使用分支：$BRANCH"
echo "提交信息：$MESSAGE"

# 确保在 Git 仓库中
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "当前目录不是 Git 仓库！"
    exit 1
fi

# 添加 & 提交
git add .
git commit -m "$MESSAGE"

# 获取远程最新
git fetch origin "$BRANCH"

# 检查是否有冲突（本地和远程是否一致）
LOCAL=$(git rev-parse "$BRANCH")
REMOTE=$(git rev-parse "origin/$BRANCH")
BASE=$(git merge-base "$BRANCH" "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "本地与远程一致，正常推送..."
    git push origin "$BRANCH"
elif [ "$LOCAL" = "$BASE" ]; then
    echo "本地落后远程，需要 pull..."
    echo "请选择操作："
    echo "1. 备份当前为 $BRANCH-backup 并强制同步远程"
    echo "2. 强制拉取（丢弃本地改动）"
    read -p "输入选项 (1/2): " option
    case "$option" in
        1)
            git branch "${BRANCH}-backup"
            git reset --hard "origin/$BRANCH"
            echo "已创建本地备份并同步远程"
            ;;
        2)
            git reset --hard "origin/$BRANCH"
            echo "已强制拉取远程代码"
            ;;
        *)
            echo "无效选项，操作取消"
            exit 1
            ;;
    esac
elif [ "$REMOTE" = "$BASE" ]; then
    echo "远程落后，准备 push..."
    git push origin "$BRANCH"
else
    echo "本地和远程都有修改，存在冲突"
    echo "请选择操作："
    echo "1. 新建分支并 push（如：$BRANCH-conflict）"
    echo "2. 强制 push，覆盖远程版本（慎用）"
    read -p "输入选项 (1/2): " option
    case "$option" in
        1)
            NEW_BRANCH="${BRANCH}-conflict-$(date +%Y%m%d%H%M%S)"
            git checkout -b "$NEW_BRANCH"
            git push origin "$NEW_BRANCH"
            echo "已创建并推送新分支：$NEW_BRANCH"
            ;;
        2)
            git push origin "$BRANCH" --force
            echo "已强制覆盖远程分支"
            ;;
        *)
            echo "无效选项，操作取消"
            exit 1
            ;;
    esac
fi
