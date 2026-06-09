#!/bin/bash
set -euo pipefail

# ==================== 全局配置 ====================
# 临时工作目录
TMP_DIR="./tmp"
# 当前工作目录
PWD_DIR=$(pwd)
# 关联数组存储包的更新日期
declare -A DATE_MAP=()
# 关联数组存储包的详细信息（用于显示）
declare -A PACKAGE_INFO=()
# 数组存储拉取失败的包
declare -a FAILED_PACKAGES=()

# ==================== 核心工具函数 ====================

# 函数：从 README.md 中读取指定包的更新日期
# 参数1：包名称
# 返回：更新日期（YYYYMMDD格式），如果未找到返回空
get_update_date_from_readme() {
    local pkg_name="$1"
    local update_date=""
    
    if [ -f "README.md" ]; then
        # 查找包含该包名的行，提取更新日期（第7列）
        # 表格格式：|软件|分支|作者|功能|包类型|更新日期|应用包|
        while IFS= read -r line; do
            if [[ "$line" == \|*\|*\|*\|*\|*\|*\|*\| ]]; then
                local col1=$(echo "$line" | cut -d'|' -f2 | xargs)
                # 解析 [名称](链接) 格式
                if [[ "$col1" =~ \[(.*)\]\((.*)\) ]]; then
                    local name="${BASH_REMATCH[1]}"
                    if [[ "$name" == "$pkg_name" ]]; then
                        # 更新日期在第7列
                        update_date=$(echo "$line" | cut -d'|' -f7 | xargs)
                        break
                    fi
                fi
            fi
        done < "README.md"
    fi
    
    echo "$update_date"
}

# 函数：克隆仓库 + 切换分支 + 获取最新提交日期
# 参数1：仓库地址 | 参数2：保存路径 | 参数3：分支名
download_repo() {
    local repo="$1"
    local path="$2"
    local branch="$3"

    echo -e "\n🔽 正在拉取仓库：$repo" >&2
    # 清空旧目录，保证纯净克隆
    [ -d "$path" ] && rm -rf "$path"

    # 静默克隆仓库
    if ! git clone "$repo" "$path" >/dev/null 2>&1; then
        echo "❌ 克隆失败：$repo" >&2
        return 1
    fi

    # 切换到仓库目录
    if ! cd "$path"; then
        echo "❌ 无法进入目录：$path" >&2
        return 1
    fi

    # 切换指定分支
    if ! git checkout "$branch" >/dev/null 2>&1; then
        cd "$PWD_DIR" || return 1
        echo "❌ 切换分支失败：$branch" >&2
        return 1
    fi

    # 获取最新提交日期 格式 YYYYMMDD
    local commit_date
    commit_date=$(git log --date=format:%Y%m%d --max-count=1 | grep Date: | awk '{print $2}')

    # 返回原目录
    cd "$PWD_DIR" || return 1
    echo "$commit_date"
}

# 函数：扫描有效插件目录
# 过滤：隐藏目录、doc、previews、无用目录
list_dir() {
    local path="$1"
    find "$path" -maxdepth 1 -type d | tail -n +2 | while read -r dir; do
        local name
        name=$(basename "$dir")
        if [[ ! "$name" =~ ^\. && "$name" != "doc" && "$name" != "previews" && "$name" != "shadowsocksr-libev" ]]; then
            echo "$dir"
        fi
    done
}

# 函数：删除隐藏目录（清理.git等冗余文件）
remove_hidden_dirs() {
    local path="$1"
    find "$path" -maxdepth 1 -type d -name ".*" -exec rm -rf {} \;
}

# 函数：应用包白名单过滤（核心！实现多包精选）
# 只保留 README【应用包】列填写的插件
filter_allow_pkg() {
    local all_dirs=("$@")
    local allow_list=(${ALLOW_PKG_STR})
    local res=()

    for dir in "${all_dirs[@]}"; do
        local pkg_name
        pkg_name=$(basename "$dir")
        # 白名单为空=全量同步，不为空=精准匹配
        if [[ ${#allow_list[@]} -eq 0 || " ${allow_list[@]} " =~ " ${pkg_name} " ]]; then
            res+=("$dir")
        fi
    done

    echo "${res[@]}"
}

# ==================== 单包更新主逻辑 ====================
update_package() {
    # 接收7个参数：名称|仓库|分支|作者|功能|包类型|应用包
    local name="$1"
    local repo="$2"
    local branch="$3"
    local developer="$4"
    local function="$5"
    local pkg_type="$6"
    local allow_pkg="$7"

    local tmp_path="${TMP_DIR}/${name}"
    local local_update_date=""
    
    # 检查本地是否已有该包，并获取本地更新日期
    if [ -d "${PWD_DIR}/${name}" ]; then
        local_update_date=$(get_update_date_from_readme "$name")
        if [ -n "$local_update_date" ]; then
            echo "📅 本地版本更新时间：${local_update_date}"
        else
            echo "📅 本地版本更新时间：未知"
        fi
    fi

    # 下载仓库并获取更新日期
    local commit_date
    commit_date=$(download_repo "$repo" "$tmp_path" "$branch")
    
    if [ -z "$commit_date" ]; then
        echo "❌ 仓库拉取失败：$name"
        
        # 检查本地是否已有该包
        if [ -d "${PWD_DIR}/${name}" ]; then
            echo "⚠️  保留本地已有版本：$name"
            # 从 README.md 中读取更新日期
            commit_date=$(get_update_date_from_readme "$name")
            if [ -z "$commit_date" ]; then
                commit_date="本地版本"
            fi
            DATE_MAP["$name"]="$commit_date"
        else
            echo "❌ 本地无此包，记录失败：$name"
            FAILED_PACKAGES+=("$name|$repo|$branch")
        fi
        return
    fi

    # 显示远程更新时间
    echo "📅 远程版本更新时间：${commit_date}"
    
    # 对比更新时间
    if [ -n "$local_update_date" ] && [ "$local_update_date" != "未知" ]; then
        if [ "$commit_date" \> "$local_update_date" ]; then
            echo "🔄 检测到新版本，准备更新..."
        elif [ "$commit_date" = "$local_update_date" ]; then
            echo "✅ 版本已是最新"
        else
            echo "⚠️  远程版本早于本地版本"
        fi
    fi

    # 全局记录更新日期，用于写入README
    DATE_MAP["$name"]="$commit_date"

    local dirList=()
    # 赋值当前包的应用包白名单
    ALLOW_PKG_STR="${allow_pkg}"

    # 多包仓库处理逻辑（multi）
    if [ "${pkg_type}" = "multi" ]; then
        # 特殊适配：luci-app-store 仓库二级目录
        [ "${name}" = "luci-app-store" ] && tmp_path="${tmp_path}/luci"

        # 扫描所有子包 + 白名单过滤
        local allDirs=($(list_dir "${tmp_path}"))
        dirList=($(filter_allow_pkg "${allDirs[@]}"))
    else
        # 单包仓库处理逻辑（single）
        remove_hidden_dirs "${tmp_path}"
        dirList=("${tmp_path}")
    fi

    # 移动插件到根目录，覆盖旧版本
    for dir in "${dirList[@]}"; do
        local target="${PWD_DIR}/$(basename "$dir")"
        [ -d "$target" ] && rm -rf "$target"
        mv "$dir" "${PWD_DIR}/"
        echo "✅ 同步完成：$(basename "$dir")"
    done
}

# ==================== 解析 README.md 清单 ====================
# 解析表格7列：软件|分支|作者|功能|包类型|更新日期|应用包
# 全局数组存储包列表
declare -a PACKAGE_LIST=()

get_package_list() {
    PACKAGE_LIST=()
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 匹配标准表格行
        if [[ "$line" == \|*\|*\|*\|*\|*\|*\|*\| ]]; then
            local col1=$(echo "$line" | cut -d'|' -f2 | xargs)
            local branch=$(echo "$line" | cut -d'|' -f3 | xargs)
            local author=$(echo "$line" | cut -d'|' -f4 | xargs)
            local func=$(echo "$line" | cut -d'|' -f5 | xargs)
            local pkg_type=$(echo "$line" | cut -d'|' -f6 | xargs)
            local allow_pkg=$(echo "$line" | cut -d'|' -f8 | xargs)

            # 解析 [名称](链接) 格式
            if [[ "$col1" =~ \[(.*)\]\((.*)\) ]]; then
                local pkg_name="${BASH_REMATCH[1]}"
                local pkg_url="${BASH_REMATCH[2]}.git"
                # 拼接成管道分隔字符串
                PACKAGE_LIST+=("${pkg_name}|${pkg_url}|${branch}|${author}|${func}|${pkg_type}|${allow_pkg}")
                # 记录包的详细信息用于显示
                PACKAGE_INFO["$pkg_name"]="分支:${branch}|作者:${author}|类型:${pkg_type}|应用包:${allow_pkg}"
                count=$((count + 1))
            fi
        fi
    done < "README.md"

    # 显示解析结果
    echo "📋 共解析到 ${count} 个插件包"
}

# ==================== 自动生成最新 README.md ====================
create_readme() {
    # 备份原始 README.md，防止数据丢失
    if [ -f "README.md" ]; then
        cp README.md README.md.bak
    fi

    rm -f README.md

    # 写入固定头部内容
    cat > README.md << 'EOF'
# OpenWrt-Packages
常用 OpenWrt 软件包收集

## 注意事项
1. 适用于 OpenWrt 25.x 版本。

## 软件清单
|软件|分支|作者|功能|包类型|更新日期|应用包|
|:-|:-|:-|:-|:-|:-|:-|
EOF

    # 逐行写入插件数据
    for pkg in "${PACKAGE_LIST[@]}"; do
        IFS='|' read -r name repo branch author func pkg_type allow_pkg <<< "$pkg"
        update_date="${DATE_MAP[$name]}"
        repo_raw=${repo%.git}
        echo "|[${name}](${repo_raw})|${branch}|${author}|${func}|${pkg_type}|${update_date}|${allow_pkg}|" >> README.md
    done

    # 如果没有数据行，恢复备份
    if [ ${#PACKAGE_LIST[@]} -eq 0 ] && [ -f "README.md.bak" ]; then
        echo "⚠️ 警告：未找到包数据，恢复原始 README.md"
        mv README.md.bak README.md
    else
        rm -f README.md.bak
    fi
}

# ==================== 程序主入口 ====================
main() {
    # 创建临时目录
    mkdir -p "${TMP_DIR}"

    echo "📦 解析插件清单，开始同步..."
    get_package_list

    # 遍历同步所有插件
    local total=${#PACKAGE_LIST[@]}
    local current=0
    for pkg in "${PACKAGE_LIST[@]}"; do
        IFS='|' read -r name repo branch author func pkg_type allow_pkg <<< "$pkg"
        current=$((current + 1))
        echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📦 [${current}/${total}] 正在处理：${name}"
        echo "   ├─ 仓库：${repo%.git}"
        echo "   ├─ 分支：${branch}"
        echo "   ├─ 作者：${author}"
        echo "   ├─ 类型：${pkg_type}"
        if [ -n "$allow_pkg" ]; then
            echo "   └─ 应用包：${allow_pkg}"
        else
            echo "   └─ 应用包：全部"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        update_package "$name" "$repo" "$branch" "$author" "$func" "$pkg_type" "$allow_pkg"
    done

    # 生成最新README
    echo -e "\n📝 生成最新软件清单..."
    create_readme

    # 清理临时文件（兼容 Windows 和 Linux）
    echo "🧹 清理临时文件..."
    if [ -d "${TMP_DIR}" ]; then
        # 先清空文件夹内容
        find "${TMP_DIR}" -mindepth 1 -delete 2>/dev/null || rm -rf "${TMP_DIR}"/*
        # 再删除文件夹本身
        rmdir "${TMP_DIR}" 2>/dev/null || rm -rf "${TMP_DIR}"
        echo "✅ 临时文件夹清理完成"
    fi

    # 显示统计信息
    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 同步统计报告"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local success_count=$((total - ${#FAILED_PACKAGES[@]}))
    echo "✅ 成功：${success_count} 个"
    echo "❌ 失败：${#FAILED_PACKAGES[@]} 个"

    # 显示失败的插件详情
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n⚠️  失败的插件列表："
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for failed in "${FAILED_PACKAGES[@]}"; do
            IFS='|' read -r name repo branch <<< "$failed"
            echo "❌ ${name}"
            echo "   ├─ 仓库：${repo%.git}"
            echo "   └─ 分支：${branch}"
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    echo -e "\n🎉 所有插件同步完成！"
}

# 启动程序
main
