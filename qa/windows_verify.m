function windows_verify(taskRoot, inputRoot, referenceRoot, implementationRoot, evidenceRoot)
arguments
    taskRoot (1,1) string
    inputRoot (1,1) string
    referenceRoot (1,1) string
    implementationRoot (1,1) string
    evidenceRoot (1,1) string
end

addpath(implementationRoot);
if isfolder(evidenceRoot)
    rmdir(evidenceRoot, 's');
end
mkdir(evidenceRoot);
tempRoot = string(tempname);
mkdir(tempRoot);
cleanup = onCleanup(@() removeTree(tempRoot));

referenceFiles = relativeFiles(referenceRoot);
cleanRuns = struct([]);
for rootIndex = 1:2
    rootId = "clean-" + char('a' + rootIndex - 1);
    root = fullfile(tempRoot, rootId);
    input = fullfile(root, 'input');
    mkdir(input);
    copyfile(fullfile(inputRoot, '*'), input);
    before = treeHashes(input);
    runItems = struct([]);
    for runIndex = 1:2
        output = fullfile(root, "output-" + runIndex);
        analyze_fan_orders(input, output);
        assertTreesEqual(output, referenceRoot);
        runItems(runIndex).run_id = runIndex;
        runItems(runIndex).return_code = 0;
        runItems(runIndex).output_started_empty = true;
        runItems(runIndex).reference_match = true;
    end
    if ~isequal(before, treeHashes(input))
        error('ALE:InputChanged', '输入文件在运行后发生变化');
    end
    cleanRuns(rootIndex).root_id = rootId;
    cleanRuns(rootIndex).input_unchanged = true;
    cleanRuns(rootIndex).runs = runItems;
end

mutationInput = fullfile(tempRoot, 'positive-input');
mutationOutput = fullfile(tempRoot, 'positive-output');
mkdir(mutationInput);
copyfile(fullfile(inputRoot, '*'), mutationInput);
limitPath = fullfile(mutationInput, 'alarm_limits.csv');
limits = readtable(limitPath, TextType='string');
row = limits.sensor_axis == "radial" & limits.order_x == 1;
limits.alarm_amplitude_g(row) = 0.700;
writetable(limits, limitPath);
analyze_fan_orders(mutationInput, mutationOutput);
mutatedRisks = readtable(fullfile(mutationOutput, 'results', 'risk_bands.csv'), TextType='string');
mutatedProgram = readtable(fullfile(mutationOutput, 'results', 'next_test_program.csv'), TextType='string');
if any(mutatedRisks.sensor_axis == "radial" & mutatedRisks.order_x == 1)
    error('ALE:MutationRisk', '提高1x报警限值后仍产生radial 1x风险段');
end
if mutatedProgram.crossed_risk_class(2) ~= "CLEAR"
    error('ALE:MutationProgram', '报警限值变化没有改变第二段穿越类别');
end

negativeInput = fullfile(tempRoot, 'negative-input');
negativeOutput = fullfile(tempRoot, 'negative-output');
mkdir(negativeInput);
copyfile(fullfile(inputRoot, '*'), negativeInput);
windowPath = fullfile(negativeInput, 'order_windows_A.csv');
windows = readtable(windowPath, TextType='string');
windows(end+1,:) = windows(1,:);
writetable(windows, windowPath);
negativeFailed = false;
negativeMessage = "";
try
    analyze_fan_orders(negativeInput, negativeOutput);
catch errorValue
    negativeFailed = true;
    negativeMessage = string(errorValue.identifier) + ":" + string(errorValue.message);
end
if isfolder(negativeOutput)
    negativeArtifacts = relativeFiles(negativeOutput);
else
    negativeArtifacts = strings(0,1);
end
if ~negativeFailed || ~isempty(negativeArtifacts)
    error('ALE:NegativeCase', '重复业务键没有失败关闭');
end
writeText(fullfile(evidenceRoot, 'negative-case.log'), negativeMessage + newline);

attachmentNames = ["输入数据包.zip","reference.zip","关键标准答案.xlsx","任务规格转化.xlsx"];
attachments = struct();
for index = 1:numel(attachmentNames)
    key = "artifact_" + index;
    attachments.(key).name = attachmentNames(index);
    attachments.(key).sha256 = sha256(fullfile(taskRoot, attachmentNames(index)));
end

summary.schema_version = 1;
summary.result = 'PASS';
summary.task_id = '2207';
summary.task_slug = 'fan_runup_order_risk_review';
summary.runner.os = getenv('RUNNER_OS');
summary.runner.image_os = getenv('ImageOS');
summary.runner.architecture = computer('arch');
summary.commit_sha = getenv('GITHUB_SHA');
summary.workflow_run_id = str2double(getenv('GITHUB_RUN_ID'));
summary.primary_software.name = 'MATLAB';
summary.primary_software.version = version;
summary.primary_software.executed = true;
summary.attachments = attachments;
summary.generated_paths = referenceFiles;
summary.clean_directory_count = 2;
summary.process_runs_per_directory = 2;
summary.clean_runs = cleanRuns;
summary.positive_mutation.name = 'radial 1x报警幅值由0.450g提高到0.700g';
summary.positive_mutation.input_changed = true;
summary.positive_mutation.behavior_changed = true;
summary.positive_mutation.step2_class = char(mutatedProgram.crossed_risk_class(2));
summary.positive_mutation.assertions_passed = true;
summary.negative_case.name = 'order_windows_A.csv出现重复业务键';
summary.negative_case.return_code = 1;
summary.negative_case.failed_closed = true;
summary.negative_case.no_stale_deliverables = true;
summary.reference_match = true;
writeText(fullfile(evidenceRoot, 'windows-summary.json'), string(jsonencode(summary, PrettyPrint=true)) + newline);
end

function files = relativeFiles(root)
items = dir(fullfile(root, '**', '*'));
items = items(~[items.isdir]);
files = strings(numel(items),1);
prefix = string(root) + filesep;
for index = 1:numel(items)
    full = string(fullfile(items(index).folder, items(index).name));
    files(index) = replace(extractAfter(full, strlength(prefix)), '\', '/');
end
files = sort(files);
end

function hashes = treeHashes(root)
files = relativeFiles(root);
hashes = strings(numel(files),2);
for index = 1:numel(files)
    hashes(index,1) = files(index);
    hashes(index,2) = sha256(fullfile(root, files(index)));
end
end

function assertTreesEqual(actual, expected)
actualFiles = relativeFiles(actual);
expectedFiles = relativeFiles(expected);
if ~isequal(actualFiles, expectedFiles)
    error('ALE:FileSet', '交付文件集合与Reference不一致');
end
for index = 1:numel(expectedFiles)
    left = readBytes(fullfile(actual, expectedFiles(index)));
    right = readBytes(fullfile(expected, expectedFiles(index)));
    if ~isequal(left, right)
        error('ALE:FileContent', '交付文件与Reference不一致:%s', expectedFiles(index));
    end
end
end

function bytes = readBytes(file)
handle = fopen(file, 'rb');
if handle < 0
    error('ALE:ReadFile', '无法读取文件');
end
cleaner = onCleanup(@() fclose(handle));
bytes = fread(handle, Inf, '*uint8');
end

function hash = sha256(file)
bytes = readBytes(file);
digest = java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(bytes, 'int8'));
raw = typecast(digest.digest(), 'uint8');
hash = lower(reshape(dec2hex(raw,2).',1,[]));
end

function writeText(file, value)
handle = fopen(file, 'w', 'n', 'UTF-8');
if handle < 0
    error('ALE:WriteFile', '无法写入文件');
end
cleaner = onCleanup(@() fclose(handle));
fprintf(handle, '%s', char(value));
end

function removeTree(root)
if isfolder(root)
    try
        rmdir(root, 's');
    catch
    end
end
end
