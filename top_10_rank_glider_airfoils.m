%% MULTI-ATTRIBUTE AIRFOIL RANKING PIPELINE (FIXED)
% Objective: Best Distance (50%), Longest Flight Time (35%), Trim Penalty (15%)
clear; clc; close all;

data_dir = 'polar_data';

if ~exist(data_dir, 'dir')
    error('Folder "%s" not found in MATLAB Drive. Run: unzip(''polar_data.zip''); first.', data_dir);
end

% Collect all polar text files from folder and subfolders
files = dir(fullfile(data_dir, '**', '*.*'));
valid_exts = {'.txt', '.plr', '.csv', '.dat', ''};

file_list = {};
for i = 1:length(files)
    [~, ~, ext] = fileparts(files(i).name);
    if ~files(i).isdir && ismember(lower(ext), valid_exts) && ...
       ~contains(files(i).name, 'AIRFOILS') && ~endsWith(files(i).name, '.m')
        file_list{end+1} = fullfile(files(i).folder, files(i).name); %#ok<SAGROW>
    end
end

if isempty(file_list)
    error('No polar files found inside "%s". Check the unzipped contents.', data_dir);
end

airfoil_map = containers.Map();

%% 1. Parse and Extract Performance Metrics
for k = 1:length(file_list)
    fp = file_list{k};
    fid = fopen(fp, 'r');
    if fid == -1, continue; end
    
    foil_name = 'Unknown';
    re_val = 'Unknown';
    
    for l = 1:15
        tline = fgetl(fid);
        if ~ischar(tline), break; end
        if contains(tline, 'Calculated polar for:')
            foil_name = strtrim(strrep(tline, 'Calculated polar for:', ''));
        elseif contains(tline, 'Re =')
            tok = regexp(tline, 'Re\s*=\s*([\d\.\s\w]+)', 'tokens');
            if ~isempty(tok), re_val = strtrim(tok{1}{1}); end
        end
    end
    fclose(fid);
    
    if strcmp(foil_name, 'Unknown') || isempty(foil_name)
        [~, base_name, ~] = fileparts(fp);
        foil_name = regexprep(base_name, '_T\d+_Re.*$', '');
    end
    
    try
        raw = readmatrix(fp, 'HeaderLines', 11);
    catch
        continue;
    end
    
    if isempty(raw) || size(raw, 1) < 4 || size(raw, 2) < 5
        continue;
    end
    
    alpha = raw(:, 1);
    cl    = raw(:, 2);
    cd    = raw(:, 3);
    cm    = raw(:, 5);
    
    valid = (cd > 0) & (cl > 0);
    if sum(valid) < 3, continue; end
    
    alpha = alpha(valid);
    cl    = cl(valid);
    cd    = cd(valid);
    cm    = cm(valid);
    
    ld = cl ./ cd;
    pf = (cl .^ 1.5) ./ cd;
    
    [max_ld, idx_ld] = max(ld);
    [max_pf, ~]      = max(pf);
    [max_cl, ~]      = max(cl);
    
    % Zero-lift pitch moment closest to alpha = 0 deg
    [~, idx_cm0]     = min(abs(alpha - 0.0));
    cm0_val          = cm(idx_cm0);
    
    % Retain best-performing sweep per airfoil
    if ~isKey(airfoil_map, foil_name) || max_ld > airfoil_map(foil_name).Max_L_D
        entry.Name        = foil_name;
        entry.Re          = re_val;
        entry.Max_L_D     = round(max_ld, 2);
        entry.Alpha_L_D   = alpha(idx_ld);
        entry.CL_at_LD    = round(cl(idx_ld), 3);
        entry.CD_at_LD    = round(cd(idx_ld), 4);
        entry.Max_CL      = round(max_cl, 3);
        entry.Max_PF      = round(max_pf, 2);  % Fixed: stores as Max_PF
        entry.Cm0         = round(cm0_val, 3);
        entry.alpha       = alpha;
        entry.cl          = cl;
        entry.cd          = cd;
        entry.cm          = cm;
        entry.cl_cd       = ld;
        airfoil_map(foil_name) = entry;
    end
end

%% 2. Calculate Weighted Composite Objective Score
all_keys = airfoil_map.keys();
N = length(all_keys);
foils = cell(N, 1);
for i = 1:N
    foils{i} = airfoil_map(all_keys{i});
end

all_ld  = cellfun(@(x) x.Max_L_D, foils);
all_pf  = cellfun(@(x) x.Max_PF, foils);
all_cm0 = abs(cellfun(@(x) x.Cm0, foils));

% Min-Max Normalization (0 to 1)
norm_ld  = (all_ld - min(all_ld)) ./ (max(all_ld) - min(all_ld) + eps);
norm_pf  = (all_pf - min(all_pf)) ./ (max(all_pf) - min(all_pf) + eps);
norm_cm  = 1.0 - ((all_cm0 - min(all_cm0)) ./ (max(all_cm0) - min(all_cm0) + eps));

% 50% Distance + 35% Flight Time + 15% Trim Stability
for i = 1:N
    foils{i}.Score = (0.50 * norm_ld(i) + 0.35 * norm_pf(i) + 0.15 * norm_cm(i)) * 100;
end

[~, sort_idx] = sort(cellfun(@(x) x.Score, foils), 'descend');
sorted_foils = foils(sort_idx);

%% 3. Print Ranked Table to Command Window
fprintf('=========================================================================================\n');
fprintf('Rank  Airfoil                     Score   Max L/D   Opt Alpha  Max Cl^1.5/Cd  Max Cl   Cm0\n');
fprintf('=========================================================================================\n');
num_top = min(10, length(sorted_foils));
for i = 1:num_top
    f = sorted_foils{i};
    fprintf('%-5d %-26s %-7.1f %-9.2f %-10.1f %-14.2f %-8.3f %-6.3f\n', ...
        i, f.Name(1:min(25, length(f.Name))), f.Score, f.Max_L_D, f.Alpha_L_D, f.Max_PF, f.Max_CL, f.Cm0);
end
fprintf('=========================================================================================\n\n');

%% 4. Export Top 10 to CSV
csv_out = 'TOP_10_WEIGHTED_AIRFOILS.csv';
fid = fopen(csv_out, 'w');
if fid ~= -1
    fprintf(fid, 'Rank,Airfoil,Score,Max_L_D,Alpha_at_Max_L_D,CL_at_Max_L_D,CD_at_Max_L_D,Max_CL,Max_CL1.5_CD,Cm0\n');
    for i = 1:num_top
        f = sorted_foils{i};
        fprintf(fid, '%d,"%s",%.2f,%.2f,%.2f,%.3f,%.4f,%.3f,%.2f,%.3f\n', ...
            i, f.Name, f.Score, f.Max_L_D, f.Alpha_L_D, f.CL_at_LD, f.CD_at_LD, f.Max_CL, f.Max_PF, f.Cm0);
    end
    fclose(fid);
    fprintf('[OK] Top 10 exported to: %s\n', csv_out);
end

%% 5. Four-Quadrant Comparison Plots for Top 5 Candidates
figure('Name', 'Top 5 Candidate Airfoils Polar Comparison', 'Color', 'w', 'Position', [100, 100, 950, 700]);
top_plot = min(5, length(sorted_foils));
colors = lines(top_plot);

for i = 1:top_plot
    f = sorted_foils{i};
    
    subplot(2,2,1); hold on; grid on;
    plot(f.cd, f.cl, 'Color', colors(i,:), 'LineWidth', 1.8, 'DisplayName', f.Name);
    xlabel('C_d'); ylabel('C_l'); title('Drag Polar (C_l vs C_d)');
    
    subplot(2,2,2); hold on; grid on;
    plot(f.alpha, f.cl, 'Color', colors(i,:), 'LineWidth', 1.8, 'DisplayName', f.Name);
    xlabel('\alpha (deg)'); ylabel('C_l'); title('Lift Curve (C_l vs \alpha)');
    
    subplot(2,2,3); hold on; grid on;
    plot(f.alpha, f.cl_cd, 'Color', colors(i,:), 'LineWidth', 1.8, 'DisplayName', f.Name);
    xlabel('\alpha (deg)'); ylabel('C_l / C_d'); title('Glide Ratio (C_l/C_d vs \alpha)');
    
    subplot(2,2,4); hold on; grid on;
    plot(f.alpha, f.cm, 'Color', colors(i,:), 'LineWidth', 1.8, 'DisplayName', f.Name);
    xlabel('\alpha (deg)'); ylabel('C_m'); title('Pitching Moment (C_m vs \alpha)');
end

for sp = 1:4
    subplot(2,2,sp);
    legend('Location', 'best', 'FontSize', 8, 'Interpreter', 'none');
end