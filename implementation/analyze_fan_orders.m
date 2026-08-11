function analyze_fan_orders(inputRoot, outputRoot)
arguments
    inputRoot (1,1) string
    outputRoot (1,1) string
end

if isfolder(outputRoot) && ~isempty(dir(outputRoot))
    error('ALE:OutputNotEmpty', '输出目录必须为空');
end
if isfolder(outputRoot)
    rmdir(outputRoot, 's');
end
mkdir(outputRoot);
completionMarker = fullfile(outputRoot, '.complete');
cleanup = onCleanup(@() cleanupOnFailure(outputRoot, completionMarker));

runA = readtable(fullfile(inputRoot, 'order_windows_A.csv'), TextType='string');
runB = readtable(fullfile(inputRoot, 'order_windows_B.csv'), TextType='string');
limits = readtable(fullfile(inputRoot, 'alarm_limits.csv'), TextType='string');
candidates = readtable(fullfile(inputRoot, 'candidate_speeds.csv'), TextType='string');
rules = readtable(fullfile(inputRoot, 'test_plan_rules.csv'), TextType='string');

requiredWindowFields = {'window_id','run_id','sensor_axis','order_x','rpm_center','amplitude_g'};
assertFields(runA, requiredWindowFields, 'order_windows_A.csv');
assertFields(runB, requiredWindowFields, 'order_windows_B.csv');
assertFields(limits, {'sensor_axis','order_x','alarm_amplitude_g','minimum_consecutive_windows','merge_gap_rpm','repeat_overlap_rpm','safety_margin_rpm'}, 'alarm_limits.csv');
assertFields(candidates, {'speed_rpm','priority','dwell_seconds'}, 'candidate_speeds.csv');
assertFields(rules, {'rule_key','value','unit'}, 'test_plan_rules.csv');

windows = [runA; runB];
windows.run_id = string(windows.run_id);
windows.sensor_axis = string(windows.sensor_axis);
windows.window_id = string(windows.window_id);
limits.sensor_axis = string(limits.sensor_axis);
rules.rule_key = string(rules.rule_key);

keys = windows.run_id + '|' + windows.window_id;
if numel(unique(keys)) ~= height(windows)
    error('ALE:DuplicateWindow', '试验窗业务主键重复');
end
if any(~ismember(windows.run_id, ["A","B"])) || any(windows.rpm_center <= 0) || any(windows.amplitude_g < 0)
    error('ALE:InvalidWindow', '阶次窗含非法运行、转速或幅值');
end

limitKeys = limits.sensor_axis + '|' + string(limits.order_x);
if numel(unique(limitKeys)) ~= height(limits)
    error('ALE:DuplicateLimit', '报警限值业务键重复');
end
windowCombos = unique(windows.sensor_axis + '|' + string(windows.order_x));
if ~isequal(sort(windowCombos), sort(limitKeys))
    error('ALE:LimitCoverage', '报警限值没有完整覆盖阶次窗组合');
end

summary = buildSummary(windows, limits);
segments = buildSegments(windows, limits);
riskBands = matchSegments(segments, windows, limits, rules);
program = buildProgram(candidates, riskBands, rules);

mkdir(fullfile(outputRoot, 'src'));
mkdir(fullfile(outputRoot, 'results'));
mkdir(fullfile(outputRoot, 'figures'));
copyfile([mfilename('fullpath') '.m'], fullfile(outputRoot, 'src', 'analyze_fan_orders.m'));
writetable(summary, fullfile(outputRoot, 'results', 'order_summary.csv'));
writetable(riskBands, fullfile(outputRoot, 'results', 'risk_bands.csv'));
writetable(program, fullfile(outputRoot, 'results', 'next_test_program.csv'));
writeFigure(windows, limits, riskBands, fullfile(outputRoot, 'figures', 'order_trends.png'));
writeReadme(fullfile(outputRoot, 'README.md'));

file = fopen(completionMarker, 'w');
fclose(file);
end

function summary = buildSummary(windows, limits)
summary = table('Size',[0 6], ...
    'VariableTypes', {'string','string','double','double','double','double'}, ...
    'VariableNames', {'run_id','sensor_axis','order_x','peak_amplitude_g','peak_rpm','alarm_window_count'});
for run = ["A","B"]
    for index = 1:height(limits)
        rows = windows.run_id == run & windows.sensor_axis == limits.sensor_axis(index) & windows.order_x == limits.order_x(index);
        selected = windows(rows,:);
        [peak, location] = max(selected.amplitude_g);
        alarmCount = sum(selected.amplitude_g >= limits.alarm_amplitude_g(index));
        summary(end+1,:) = {run, limits.sensor_axis(index), limits.order_x(index), peak, selected.rpm_center(location), alarmCount}; %#ok<AGROW>
    end
end
summary = sortrows(summary, {'run_id','sensor_axis','order_x'});
end

function segments = buildSegments(windows, limits)
segments = table('Size',[0 8], ...
    'VariableTypes', {'string','string','double','double','double','double','double','double'}, ...
    'VariableNames', {'run_id','sensor_axis','order_x','start_rpm','end_rpm','peak_amplitude_g','window_count','limit_index'});
for run = ["A","B"]
    for index = 1:height(limits)
        rows = windows.run_id == run & windows.sensor_axis == limits.sensor_axis(index) & windows.order_x == limits.order_x(index) & windows.amplitude_g >= limits.alarm_amplitude_g(index);
        selected = sortrows(windows(rows,:), 'rpm_center');
        if isempty(selected)
            continue
        end
        group = [1; cumsum(diff(selected.rpm_center) > limits.merge_gap_rpm(index)) + 1];
        for groupId = unique(group)'
            member = selected(group == groupId,:);
            if height(member) < limits.minimum_consecutive_windows(index)
                continue
            end
            segments(end+1,:) = {run, limits.sensor_axis(index), limits.order_x(index), min(member.rpm_center), max(member.rpm_center), max(member.amplitude_g), height(member), index}; %#ok<AGROW>
        end
    end
end
end

function risks = matchSegments(segments, windows, limits, rules)
risks = table('Size',[0 10], ...
    'VariableTypes', {'string','string','double','string','string','double','double','double','double','double'}, ...
    'VariableNames', {'risk_id','sensor_axis','order_x','run_support','risk_class','observed_start_rpm','observed_end_rpm','protected_start_rpm','protected_end_rpm','peak_amplitude_g'});
matchedB = false(height(segments),1);
draft = risks;
for index = 1:height(segments)
    if segments.run_id(index) ~= "A"
        continue
    end
    possible = find(segments.run_id == "B" & segments.sensor_axis == segments.sensor_axis(index) & segments.order_x == segments.order_x(index));
    possible = possible(~matchedB(possible));
    gap = inf(size(possible));
    for item = 1:numel(possible)
        other = possible(item);
        gap(item) = max([segments.start_rpm(other) - segments.end_rpm(index), segments.start_rpm(index) - segments.end_rpm(other), 0]);
    end
    limitIndex = segments.limit_index(index);
    valid = find(gap <= limits.repeat_overlap_rpm(limitIndex), 1, 'first');
    if isempty(valid)
        draft(end+1,:) = makeRisk(segments(index,:), "A", "SINGLE_RUN", limits, rules); %#ok<AGROW>
    else
        other = possible(valid);
        matchedB(other) = true;
        combined = segments(index,:);
        combined.start_rpm = min(segments.start_rpm(index), segments.start_rpm(other));
        combined.end_rpm = max(segments.end_rpm(index), segments.end_rpm(other));
        combined.peak_amplitude_g = max(segments.peak_amplitude_g(index), segments.peak_amplitude_g(other));
        draft(end+1,:) = makeRisk(combined, "A+B", "PERSISTENT", limits, rules); %#ok<AGROW>
    end
end
for index = 1:height(segments)
    if segments.run_id(index) == "B" && ~matchedB(index)
        draft(end+1,:) = makeRisk(segments(index,:), "B", "SINGLE_RUN", limits, rules); %#ok<AGROW>
    end
end
draft = sortrows(draft, {'observed_start_rpm','sensor_axis','order_x'});
draft.risk_id = "FAN-" + compose('%02d', (1:height(draft))');
risks = draft;
end

function row = makeRisk(segment, support, riskClass, limits, rules)
limitIndex = segment.limit_index;
minimum = ruleValue(rules, 'minimum_speed_rpm');
maximum = ruleValue(rules, 'maximum_speed_rpm');
margin = limits.safety_margin_rpm(limitIndex);
row = table("", segment.sensor_axis, segment.order_x, support, riskClass, segment.start_rpm, segment.end_rpm, ...
    max(minimum, segment.start_rpm - margin), min(maximum, segment.end_rpm + margin), segment.peak_amplitude_g, ...
    'VariableNames', {'risk_id','sensor_axis','order_x','run_support','risk_class','observed_start_rpm','observed_end_rpm','protected_start_rpm','protected_end_rpm','peak_amplitude_g'});
end

function program = buildProgram(candidates, risks, rules)
candidates = sortrows(candidates, {'priority','speed_rpm'}, {'descend','ascend'});
inside = false(height(candidates),1);
for index = 1:height(candidates)
    inside(index) = any(candidates.speed_rpm(index) >= risks.protected_start_rpm & candidates.speed_rpm(index) <= risks.protected_end_rpm);
end
candidates = candidates(~inside,:);
spacing = ruleValue(rules, 'minimum_selected_spacing_rpm');
required = ruleValue(rules, 'selected_point_count');
chosen = false(height(candidates),1);
selected = [];
for index = 1:height(candidates)
    if isempty(selected) || all(abs(candidates.speed_rpm(index) - selected) >= spacing)
        chosen(index) = true;
        selected(end+1) = candidates.speed_rpm(index); %#ok<AGROW>
        if numel(selected) == required
            break
        end
    end
end
if sum(chosen) ~= required
    error('ALE:CandidateCoverage', '候选转速不足以形成计划');
end
chosenRows = sortrows(candidates(chosen,:), 'speed_rpm');
program = table('Size',[height(chosenRows) 7], ...
    'VariableTypes', {'double','double','double','double','string','string','double'}, ...
    'VariableNames', {'step_no','from_rpm','to_rpm','dwell_seconds','crossed_risk_class','crossed_risk_ids','minimum_ramp_rpm_per_s'});
from = ruleValue(rules, 'minimum_speed_rpm');
for index = 1:height(chosenRows)
    to = chosenRows.speed_rpm(index);
    crossed = risks(risks.protected_start_rpm <= to & risks.protected_end_rpm >= from,:);
    if any(crossed.risk_class == "PERSISTENT")
        riskClass = "PERSISTENT";
        ramp = ruleValue(rules, 'persistent_ramp_rpm_per_s');
    elseif ~isempty(crossed)
        riskClass = "SINGLE_RUN";
        ramp = ruleValue(rules, 'single_run_ramp_rpm_per_s');
    else
        riskClass = "CLEAR";
        ramp = ruleValue(rules, 'clear_ramp_rpm_per_s');
    end
    ids = "NONE";
    if ~isempty(crossed)
        ids = join(crossed.risk_id, '|');
    end
    program(index,:) = {index, from, to, chosenRows.dwell_seconds(index), riskClass, ids, ramp};
    from = to;
end
end

function writeFigure(windows, limits, risks, target)
figureHandle = figure('Visible','off','Color','white','Position',[100 100 1200 850]);
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
for index = 1:height(limits)
    nexttile;
    hold on;
    for run = ["A","B"]
        rows = windows.run_id == run & windows.sensor_axis == limits.sensor_axis(index) & windows.order_x == limits.order_x(index);
        selected = sortrows(windows(rows,:), 'rpm_center');
        plot(selected.rpm_center, selected.amplitude_g, 'LineWidth', 1.5, 'DisplayName', "Run " + run);
    end
    yline(limits.alarm_amplitude_g(index), '--', '报警限值', 'LineWidth', 1.2, 'HandleVisibility', 'off');
    related = risks(risks.sensor_axis == limits.sensor_axis(index) & risks.order_x == limits.order_x(index),:);
    for riskIndex = 1:height(related)
        xline(related.protected_start_rpm(riskIndex), ':', related.risk_id(riskIndex), 'HandleVisibility', 'off');
        xline(related.protected_end_rpm(riskIndex), ':', 'HandleVisibility', 'off');
    end
    grid on;
    xlabel('转速rpm');
    ylabel('幅值g');
    title(limits.sensor_axis(index) + " " + string(limits.order_x(index)) + "x阶次");
    legend('Location','best');
end
exportgraphics(figureHandle, target, 'Resolution', 120);
close(figureHandle);
end

function writeReadme(target)
lines = [
    "通风机阶次复核交付说明"
    ""
    "src/analyze_fan_orders.m读取两次阶次窗、报警限值、候选转速和试验计划规则，生成风险区与下一轮试验程序。"
    "results/order_summary.csv供设备工程师核对两次试验的峰值和超限窗。"
    "results/risk_bands.csv供调试负责人确认复现风险、单次风险和发布后的保护边界。"
    "results/next_test_program.csv供现场人员设置升速率、驻留转速和驻留时间。"
    "figures/order_trends.png用于评审会查看两次试验趋势、报警限值和风险边界。"
    ""
    "在MATLAB R2024b中把src加入路径，调用analyze_fan_orders并传入输入目录与空输出目录。程序不修改输入文件，输出目录必须为空。"
];
file = fopen(target, 'w', 'n', 'UTF-8');
if file < 0
    error('ALE:ReadmeWrite', '无法写入README.md');
end
cleaner = onCleanup(@() fclose(file));
fprintf(file, '%s\n', lines);
end

function value = ruleValue(rules, key)
row = rules.rule_key == string(key);
if sum(row) ~= 1
    error('ALE:RuleKey', '计划规则缺失或重复');
end
value = rules.value(row);
end

function assertFields(tableValue, required, fileName)
if ~all(ismember(required, tableValue.Properties.VariableNames))
    error('ALE:Fields', '%s缺少必需字段', fileName);
end
end

function cleanupOnFailure(outputRoot, completionMarker)
if isfile(completionMarker)
    delete(completionMarker);
    return
end
if isfolder(outputRoot)
    try
        rmdir(outputRoot, 's');
    catch
    end
end
end
