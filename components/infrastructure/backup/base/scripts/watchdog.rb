#!/usr/bin/env ruby
# frozen_string_literal: true

# watchdog.sh の判定。標準入力に CronJob の一覧（kubectl get cronjobs -o json）を受け取り、
# 監視対象ごとに 1 行（OK / NG）を出す。どれか NG なら終了コード 1、読めなければ 3。
#
#   ruby watchdog.rb [現在時刻（RFC3339。空なら今）] 名前=上限時間 ...
#
# 時刻は UTC で比べる。基準は status.lastSuccessfulTime。無ければ（一度も成功していなければ）
# metadata.creationTimestamp から数える。

require "json"
require "time"

def safe_dig(obj, *keys)
  cur = obj
  keys.each do |k|
    return nil unless cur.is_a?(Hash)

    cur = cur[k]
  end
  cur
end

def safe_hash(val)
  val.is_a?(Hash) ? val : {}
end

def safe_array(val)
  val.is_a?(Array) ? val : []
end

def fail_input(message)
  warn "ERROR: #{message}"
  exit 3
end

begin
  now_arg = ARGV.shift.to_s.strip
  now = now_arg.empty? ? Time.now.utc : Time.iso8601(now_arg).utc
  fail_input("監視対象が指定されていません") if ARGV.empty?

  watched = ARGV.map do |arg|
    name, hours = arg.split("=", 2)
    fail_input("監視の指定が正しくありません: #{arg}") if name.to_s.empty? || hours.to_s.empty?

    max_hours = Float(hours)
    fail_input("上限時間は正の数にしてください: #{arg}") unless max_hours.finite? && max_hours > 0

    [name, max_hours]
  end

  list = JSON.parse($stdin.read)
  fail_input("CronJob の一覧 JSON のルートがオブジェクトではありません") unless list.is_a?(Hash)

  raw_items = list["items"]
  fail_input("CronJob の一覧 JSON の items が配列ではありません") unless raw_items.nil? || raw_items.is_a?(Array)

  by_name = {}
  safe_array(raw_items).each do |cj|
    next unless cj.is_a?(Hash)

    cj_name = safe_dig(cj, "metadata", "name")
    by_name[cj_name] = cj if cj_name.is_a?(String) && !cj_name.empty?
  end

  failed = false
  watched.each do |name, max_hours|
    cj = by_name[name]
    if cj.nil?
      puts "NG  #{name}  CronJob が見つかりません（infra）"
      failed = true
      next
    end

    problems = []
    problems << "一時停止中（spec.suspend: true）" if safe_dig(cj, "spec", "suspend") == true

    last = safe_dig(cj, "status", "lastSuccessfulTime").to_s.strip
    created = safe_dig(cj, "metadata", "creationTimestamp").to_s.strip
    has_last = !last.empty?
    reference = has_last ? last : created
    if reference.empty?
      problems << "成功の記録も作成日時も無く、判定できません"
      detail = ""
    else
      begin
        since = Time.iso8601(reference).utc
        hours = (now - since) / 3600.0
        if has_last
          detail = format("最後の成功 %s（%.1f 時間前）", since.strftime("%Y-%m-%dT%H:%M:%SZ"), hours)
          problems << format("最後の成功から %.1f 時間（上限 %g 時間）", hours, max_hours) if hours > max_hours
        else
          detail = format("成功はまだ無し（作成から %.1f 時間）", hours)
          problems << format("一度も成功せず作成から %.1f 時間（上限 %g 時間）", hours, max_hours) if hours > max_hours
        end
      rescue ArgumentError
        field = has_last ? "lastSuccessfulTime" : "creationTimestamp"
        problems << "#{field} の時刻形式が不正です（#{reference}）"
        detail = ""
      end
    end

    if problems.empty?
      puts "OK  #{name}  #{detail}（上限 #{format('%g', max_hours)} 時間）"
    else
      puts "NG  #{name}  #{problems.join('、')}"
      failed = true
    end
  end

  exit 1 if failed
rescue JSON::ParserError => e
  fail_input("CronJob の一覧の JSON が読めません: #{e.message}")
rescue ArgumentError, TypeError, NoMethodError => e
  fail_input("入力を処理できません: #{e.message}")
end
