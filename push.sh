#!/bin/bash

# 颜色输出函数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 默认参数
BRANCH="main"
MESSAGE="auto commit"
BACKUP_DIR="$HOME/git-backups"

# 显示帮助信息
show_help() {
    echo "Git 一键推送脚本（SSH 密钥版）"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -b, --branch BRANCH    指定分支名称 (默认: main)"
    echo "  -m, --message MESSAGE  提交信息 (默认: auto commit)"
    echo "  -s, --setup-ssh        设置 SSH 密钥"
    echo "  -h, --help            显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                            # 使用默认设置"
    echo "  $0 -b dev -m \"修复bug\"       # 推送到dev分支"
    echo "  $0 --setup-ssh               # 设置SSH密钥"
}

# 检查SSH密钥是否存在
check_ssh_keys() {
    local ssh_dir="$HOME/.ssh"
    local key_files=("id_rsa" "id_ed25519" "id_ecdsa")
    
    for key in "${key_files[@]}"; do
        if [[ -f "$ssh_dir/$key" ]]; then
            return 0
        fi
    done
    return 1
}

# 生成SSH密钥
generate_ssh_key() {
    local ssh_dir="$HOME/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    print_info "正在生成 SSH 密钥..."
    
    read -p "请输入您的邮箱地址: " email
    if [[ -z "$email" ]]; then
        print_error "邮箱地址不能为空"
        return 1
    fi
    
    # 生成 ED25519 密钥（更安全）
    ssh-keygen -t ed25519 -C "$email" -f "$ssh_dir/id_ed25519" -N ""
    
    if [[ $? -eq 0 ]]; then
        print_success "SSH 密钥生成完成"
        chmod 600 "$ssh_dir/id_ed25519"
        chmod 644 "$ssh_dir/id_ed25519.pub"
        
        print_info "您的公钥内容如下（请复制并添加到 GitHub/GitLab）："
        echo "----------------------------------------"
        cat "$ssh_dir/id_ed25519.pub"
        echo "----------------------------------------"
        
        print_info "添加公钥步骤："
        echo "1. GitHub: Settings → SSH and GPG keys → New SSH key"
        echo "2. GitLab: Profile → SSH Keys → Add new key"
        echo "3. Gitee: 设置 → SSH公钥 → 添加公钥"
        
        read -p "按任意键继续..."
        return 0
    else
        print_error "SSH 密钥生成失败"
        return 1
    fi
}

# 测试SSH连接
test_ssh_connection() {
    local host="$1"
    
    case "$host" in
        *github.com*)
            ssh -T git@github.com -o ConnectTimeout=5 -o StrictHostKeyChecking=no 2>&1
            ;;
        *gitlab.com*)
            ssh -T git@gitlab.com -o ConnectTimeout=5 -o StrictHostKeyChecking=no 2>&1
            ;;
        *gitee.com*)
            ssh -T git@gitee.com -o ConnectTimeout=5 -o StrictHostKeyChecking=no 2>&1
            ;;
        *)
            print_warning "未知的Git服务提供商，跳过SSH测试"
            return 0
            ;;
    esac
}

# 设置SSH密钥
setup_ssh() {
    print_info "开始设置 SSH 密钥..."
    
    if check_ssh_keys; then
        print_info "发现现有 SSH 密钥"
        ls -la "$HOME/.ssh/"id_* 2>/dev/null | grep -E '\.(pub)?$'
        
        read -p "是否要生成新的密钥？(y/N): " generate_new
        if [[ "$generate_new" =~ ^[Yy]$ ]]; then
            generate_ssh_key
        fi
    else
        print_info "未找到 SSH 密钥，将生成新密钥"
        generate_ssh_key
    fi
    
    # 启动 ssh-agent 并添加密钥
    print_info "配置 SSH agent..."
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    
    # 添加所有可用的私钥
    for key in "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa"; do
        if [[ -f "$key" ]]; then
            ssh-add "$key" 2>/dev/null
            print_success "已添加密钥: $(basename "$key")"
        fi
    done
    
    print_success "SSH 设置完成！"
}

# 检查并转换远程URL为SSH格式
convert_to_ssh_url() {
    local remote_url="$1"
    
    # GitHub
    if [[ "$remote_url" =~ https://github\.com/(.+)\.git ]]; then
        echo "git@github.com:${BASH_REMATCH[1]}.git"
        return 0
    fi
    
    # GitLab
    if [[ "$remote_url" =~ https://gitlab\.com/(.+)\.git ]]; then
        echo "git@gitlab.com:${BASH_REMATCH[1]}.git"
        return 0
    fi
    
    # Gitee
    if [[ "$remote_url" =~ https://gitee\.com/(.+)\.git ]]; then
        echo "git@gitee.com:${BASH_REMATCH[1]}.git"
        return 0
    fi
    
    # 如果已经是SSH格式，直接返回
    if [[ "$remote_url" =~ ^git@.+ ]]; then
        echo "$remote_url"
        return 0
    fi
    
    # 其他情况返回原URL
    echo "$remote_url"
    return 1
}

# 自动处理安全目录问题
handle_safe_directory() {
    local current_dir="$1"
    local error_output="$2"
    
    if echo "$error_output" | grep -q "dubious ownership"; then
        print_warning "检测到 Git 安全目录问题，正在自动修复..."
        
        # 从错误信息中提取建议的命令
        if echo "$error_output" | grep -q "git config --global --add safe.directory"; then
            local safe_dir=$(echo "$error_output" | grep -o "safe\.directory [^']*" | cut -d' ' -f2 | head -1)
            if [[ -n "$safe_dir" ]]; then
                git config --global --add safe.directory "$safe_dir"
                print_success "已添加安全目录: $safe_dir"
                return 0
            fi
        fi
        
        # 备用方案：直接添加当前目录
        git config --global --add safe.directory "$current_dir"
        print_success "已添加安全目录: $current_dir"
        return 0
    fi
    
    return 1
}

# 执行Git命令并处理安全目录问题
safe_git_command() {
    local cmd="$*"
    local output
    local exit_code
    
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -q "dubious ownership"; then
        handle_safe_directory "$(pwd)" "$output"
        # 重新执行命令
        output=$(eval "$cmd" 2>&1)
        exit_code=$?
    fi
    
    echo "$output"
    return $exit_code
}

# 读取参数
SETUP_SSH=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--branch) BRANCH="$2"; shift ;;
        -m|--message) MESSAGE="$2"; shift ;;
        -s|--setup-ssh) SETUP_SSH=true ;;
        -h|--help) show_help; exit 0 ;;
        *) print_error "未知参数: $1"; show_help; exit 1 ;;
    esac
    shift
done

# 如果只是设置SSH，执行后退出
if [[ "$SETUP_SSH" == true ]]; then
    setup_ssh
    exit 0
fi

print_info "使用分支：$BRANCH"
print_info "提交信息：$MESSAGE"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 检查是否为Git仓库，不是则初始化
if ! safe_git_command "git rev-parse --is-inside-work-tree" > /dev/null 2>&1; then
    print_warning "当前目录不是 Git 仓库，正在初始化..."
    safe_git_command "git init"
    print_success "Git 仓库初始化完成"
fi

# 检查SSH密钥
if ! check_ssh_keys; then
    print_warning "未找到 SSH 密钥"
    read -p "是否现在设置 SSH 密钥？(Y/n): " setup_now
    if [[ ! "$setup_now" =~ ^[Nn]$ ]]; then
        setup_ssh
    else
        print_warning "建议使用 SSH 密钥进行身份验证，运行 '$0 --setup-ssh' 进行设置"
    fi
fi

# 启动ssh-agent并添加密钥
if check_ssh_keys; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    for key in "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa"; do
        if [[ -f "$key" ]]; then
            ssh-add "$key" 2>/dev/null
        fi
    done
fi

# 检查是否有远程仓库
if ! safe_git_command "git remote" | grep -q origin; then
    print_warning "未找到远程仓库 'origin'"
    read -p "请输入远程仓库 URL: " remote_url
    if [[ -n "$remote_url" ]]; then
        # 自动转换为SSH URL
        ssh_url=$(convert_to_ssh_url "$remote_url")
        if [[ "$ssh_url" != "$remote_url" ]]; then
            print_info "已转换为 SSH URL: $ssh_url"
            remote_url="$ssh_url"
        fi
        
        safe_git_command "git remote add origin \"$remote_url\""
        print_success "已添加远程仓库: $remote_url"
    else
        print_info "跳过远程仓库配置，仅进行本地提交"
    fi
else
    # 检查现有远程URL是否为HTTPS，建议转换为SSH
    origin_url=$(safe_git_command "git remote get-url origin" 2>/dev/null)
    if [[ "$origin_url" =~ ^https:// ]]; then
        ssh_url=$(convert_to_ssh_url "$origin_url")
        if [[ "$ssh_url" != "$origin_url" ]]; then
            print_warning "检测到 HTTPS 远程URL，建议转换为 SSH"
            read -p "是否转换为 SSH URL？(Y/n): " convert_ssh
            if [[ ! "$convert_ssh" =~ ^[Nn]$ ]]; then
                safe_git_command "git remote set-url origin \"$ssh_url\""
                print_success "已转换为 SSH URL: $ssh_url"
                
                # 测试SSH连接
                print_info "测试 SSH 连接..."
                ssh_test_result=$(test_ssh_connection "$ssh_url")
                if echo "$ssh_test_result" | grep -q "successfully authenticated"; then
                    print_success "SSH 连接测试成功"
                elif echo "$ssh_test_result" | grep -q "Welcome"; then
                    print_success "SSH 连接测试成功"
                else
                    print_warning "SSH 连接可能存在问题，请检查密钥设置"
                    print_info "测试结果: $ssh_test_result"
                fi
            fi
        fi
    fi
fi

# 配置用户信息（如果未配置）
if [[ -z "$(git config user.name)" ]]; then
    read -p "请输入您的用户名: " username
    git config --global user.name "$username"
    print_success "已设置用户名: $username"
fi

if [[ -z "$(git config user.email)" ]]; then
    read -p "请输入您的邮箱: " email
    git config --global user.email "$email"
    print_success "已设置邮箱: $email"
fi

# 检查当前分支
current_branch=$(safe_git_command "git branch --show-current" 2>/dev/null || echo "")

# 如果当前不在目标分支，切换或创建分支
if [[ "$current_branch" != "$BRANCH" ]]; then
    if safe_git_command "git show-ref --verify --quiet \"refs/heads/$BRANCH\""; then
        print_info "切换到现有分支: $BRANCH"
        safe_git_command "git checkout \"$BRANCH\""
    else
        print_info "创建新分支: $BRANCH"
        safe_git_command "git checkout -b \"$BRANCH\""
    fi
fi

# 检查是否有文件需要提交
if safe_git_command "git diff-index --quiet HEAD --" 2>/dev/null && safe_git_command "git diff --cached --quiet" 2>/dev/null; then
    print_warning "没有文件需要提交"
else
    # 显示将要提交的文件
    print_info "将要提交的文件:"
    safe_git_command "git status --porcelain" | head -10
    
    # 添加所有文件并提交
    safe_git_command "git add ."
    safe_git_command "git commit -m \"$MESSAGE\""
    print_success "本地提交完成"
fi

# 如果没有远程仓库，结束脚本
if ! safe_git_command "git remote" | grep -q origin; then
    print_success "本地操作完成（未配置远程仓库）"
    exit 0
fi

# 获取远程信息
print_info "正在获取远程仓库信息..."
if ! safe_git_command "git fetch origin \"$BRANCH\"" 2>/dev/null; then
    print_info "远程分支 $BRANCH 不存在，将创建新分支"
    safe_git_command "git push -u origin \"$BRANCH\""
    print_success "已推送新分支: $BRANCH"
    exit 0
fi

# 创建备份函数
create_backup() {
    local backup_name="backup-$(basename "$(pwd)")-$(date +%Y%m%d-%H%M%S).zip"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    print_info "正在创建项目备份..."
    if command -v zip > /dev/null; then
        zip -r "$backup_path" . -x "*.git*" "node_modules/*" "*.zip" > /dev/null 2>&1
        print_success "备份已保存至: $backup_path"
    else
        print_warning "未找到 zip 命令，使用 tar 创建备份..."
        tar -czf "${backup_path%.zip}.tar.gz" --exclude='.git' --exclude='node_modules' --exclude='*.zip' . > /dev/null 2>&1
        print_success "备份已保存至: ${backup_path%.zip}.tar.gz"
    fi
}

# 比较本地和远程
LOCAL=$(safe_git_command "git rev-parse \"$BRANCH\"" 2>/dev/null || echo "")
REMOTE=$(safe_git_command "git rev-parse \"origin/$BRANCH\"" 2>/dev/null || echo "")
BASE=$(safe_git_command "git merge-base \"$BRANCH\" \"origin/$BRANCH\"" 2>/dev/null || echo "")

if [[ "$LOCAL" == "$REMOTE" ]]; then
    print_success "本地与远程一致，无需推送"
elif [[ "$LOCAL" == "$BASE" ]]; then
    print_warning "本地落后于远程，需要更新"
    echo "请选择操作："
    echo "1. 备份本地项目并从远程同步"
    echo "2. 创建备份分支并强制同步远程"
    echo "3. 强制拉取（丢弃本地改动）"
    echo "4. 取消操作"
    read -p "输入选项 (1-4): " option
    case "$option" in
        1)
            create_backup
            safe_git_command "git reset --hard \"origin/$BRANCH\""
            print_success "已备份项目并同步远程代码"
            ;;
        2)
            backup_branch="${BRANCH}-backup-$(date +%Y%m%d%H%M%S)"
            safe_git_command "git branch \"$backup_branch\""
            safe_git_command "git reset --hard \"origin/$BRANCH\""
            print_success "已创建备份分支 $backup_branch 并同步远程"
            ;;
        3)
            safe_git_command "git reset --hard \"origin/$BRANCH\""
            print_success "已强制拉取远程代码"
            ;;
        4)
            print_info "操作已取消"
            exit 0
            ;;
        *)
            print_error "无效选项，操作取消"
            exit 1
            ;;
    esac
elif [[ "$REMOTE" == "$BASE" ]]; then
    print_info "远程落后于本地，正在推送..."
    safe_git_command "git push origin \"$BRANCH\""
    print_success "推送完成"
else
    print_warning "本地和远程都有修改，存在冲突"
    echo "请选择操作："
    echo "1. 备份本地项目并从远程重新同步"
    echo "2. 创建新分支并推送（如：$BRANCH-conflict）"
    echo "3. 强制推送，覆盖远程版本（危险操作）"
    echo "4. 取消操作"
    read -p "输入选项 (1-4): " option
    case "$option" in
        1)
            create_backup
            safe_git_command "git reset --hard \"origin/$BRANCH\""
            print_success "已备份项目并同步远程代码"
            ;;
        2)
            conflict_branch="${BRANCH}-conflict-$(date +%Y%m%d%H%M%S)"
            safe_git_command "git checkout -b \"$conflict_branch\""
            safe_git_command "git push -u origin \"$conflict_branch\""
            print_success "已创建并推送新分支：$conflict_branch"
            ;;
        3)
            print_warning "这将覆盖远程分支，确认吗？(y/N)"
            read -p "输入 y 确认: " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                safe_git_command "git push origin \"$BRANCH\" --force"
                print_success "已强制覆盖远程分支"
            else
                print_info "操作已取消"
            fi
            ;;
        4)
            print_info "操作已取消"
            exit 0
            ;;
        *)
            print_error "无效选项，操作取消"
            exit 1
            ;;
    esac
fi

print_success "脚本执行完成！"
