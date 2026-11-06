%% PARAMETRIC ASPECT RATIO (AR) SWEEP & LEADERBOARD RANKING
% Ranks Top 3 airfoils across various AR values using flow5/XFLR5 VLM2 polars
clear; clc; close all;

data_dir = 'Best_03_analysis';

if ~exist(data_dir, 'dir')
    error('Folder "%s" not found. Run: unzip(''Best_03_analysis.zip'', ''Best_03_analysis''); first.', data_dir);
end

% Recursively find all polar text files
files = dir(fullfile(data_dir, '**', '*.*'));
valid_exts = {'.txt', '.plr', '.csv', '.dat', ''};

file_list = {};
for i = 1:length(files)
    [~, ~, ext] = fileparts(files(i).name);
    if ~files(i).isdir && ismember(lower(ext), valid_exts) && ...
       ~contains(files(i).name, 'RANKING') && ~endsWith(files(i).name, '.m')
        file_list{end+1} = fullfile(files(i).folder, files(i).name); %#ok<SAGROW>
    end
end

if isempty(file_list)
    error('No polar files found inside "%s".', data_dir);
end

fprintf('Parsing %d 3D polar files from AR sweep...\n', length(file_list));

config_list = {};

%% 1. Parse Each File (Extract Airfoil, AR, and Aerodynamic Metrics)
for k = 1:length(file_list)
    fp = file_list{k};
    fid = fopen(fp, 'r');
    if fid == -1, continue; end
    
    first_line = strtrim(fgetl(fid));
    if ~ischar(first_line)
        fclose(fid);
        continue;
    end
    
    % Configuration name from line 1 (e.g., AG12_5.4) or filename fallback
    cfg_name = first_line;
    if contains(cfg_name, 'T2-VLM2') || isempty(cfg_name)
        [~, base_name, ~] = fileparts(fp);
        cfg_name = regexprep(base_name, '_T\d+.*$', '');
    end
    
    % Extract Airfoil name and AR value
    % Handles formats like: "AG12_5.4", "AG14_AR6.5", "AG13-7.2"
    ar_val = NaN;
    foil_name = cfg_name;
    
    tokens = regexp(cfg_name, '^(AG\d+|SD\d+|S\d+)[_\-\s]*(?:AR)?([0-9]*\.?[0-9]+)', 'tokens');
    if ~isempty(tokens)
        foil_name = tokens{1}{1};
        ar_val    = str2double(tokens{1}{2});
    else
        % Fallback extraction from filename
        [~, fname, ~] = fileparts(fp);
        tokens = regexp(fname, '^(AG\d+|SD\d+|S\d+)[_\-\s]*(?:AR)?([0-9]*\.?[0-9]+)', 'tokens');
        if ~isempty(tokens)
            foil_name = tokens{1}{1};
            ar_val    = str2double(tokens{1}{2});
        end
    end
    
    alphas = []; CLs = []; CDs = []; Cms = [];
    
    while ~feof(fid)
        tline = strtrim(fgetl(fid));
        if isempty(tline), continue; end
        
        parts = strsplit(tline);
        % Line 1 starts with '0' (Ctrl index)
        if length(parts) >= 12 && strcmp(parts{1}, '0')
            a_val  = str2double(parts{2});
            cl_val = str2double(parts{5});
            cd_val = str2double(parts{6});
            cm_val = str2double(parts{10}); % Pitch moment Cm
            
            if ~isnan(a_val) && ~isnan(cl_val) && ~isnan(cd_val) && cd_val > 0.005
                alphas(end+1) = a_val;  %#ok<SAGROW>
                CLs(end+1)    = cl_val; %#ok<SAGROW>
                CDs(end+1)    = cd_val; %#ok<SAGROW>
                Cms(end+1)    = cm_val; %#ok<SAGROW>
            end
        end
    end
    fclose(fid);
    
    if length(alphas) < 2, continue; end
    
    LDs = CLs ./ CDs;
    PFs = (CLs .^ 1.5) ./ CDs;
    
    [max_ld, idx_ld] = max(LDs);
    [max_pf, ~]      = max(PFs);
    
    % Zero-lift pitch moment (alpha closest to 0 deg)
    [~, idx_cm0]     = min(abs(alphas - 0.0));
    cm0_val          = Cms(idx_cm0);
    
    item.Config     = cfg_name;
    item.Airfoil    = foil_name;
    item.AR         = ar_val;
    item.Max_L_D    = round(max_ld, 3);
    item.Opt_Alpha  = alphas(idx_ld);
    item.CL_at_LD   = round(CLs(idx_ld), 3);
    item.CD_at_LD   = round(CDs(idx_ld), 4);
    item.Max_PF     = round(max_pf, 2);
    item.Cm0        = round(cm0_val, 3);
    item.alphas     = alphas;
    item.LDs        = LDs;
    item.CDs        = CDs;
    item.CLs        = CLs;
    
    config_list{end+1} = item; %#ok<SAGROW>
end

N = length(config_list);
if N == 0
    error('Could not extract valid data points. Check file headers.');
end

%% 2. Calculate Multi-Attribute Utility Score (50/35/15)
all_ld  = cellfun(@(x) x.Max_L_D, config_list);
all_pf  = cellfun(@(x) x.Max_PF, config_list);
all_cm0 = abs(cellfun(@(x) x.Cm0, config_list));

norm_ld  = (all_ld - min(all_ld)) ./ (max(all_ld) - min(all_ld) + eps);
norm_pf  = (all_pf - min(all_pf)) ./ (max(all_pf) - min(all_pf) + eps);
norm_cm  = 1.0 - ((all_cm0 - min(all_cm0)) ./ (max(all_cm0) - min(all_cm0) + eps));

for i = 1:N
    config_list{i}.Score = (0.50 * norm_ld(i) + 0.35 * norm_pf(i) + 0.15 * norm_cm(i)) * 100;
end

% Sort descending by score
[~, sort_idx] = sort(cellfun(@(x) x.Score, config_list), 'descend');
sorted_configs = config_list(sort_idx);

%% 3. Print Complete Ranked Leaderboard
fprintf('\n=================================================================================================\n');
fprintf('Rank  Configuration         Airfoil     AR      Score   3D Max L/D  Opt Alpha  CL @ L/D  CD @ L/D   Cm0\n');
fprintf('=================================================================================================\n');
for i = 1:N
    c = sorted_configs{i};
    fprintf('%-5d %-21s %-11s %-7.2f %-7.1f %-11.3f %-10.1f %-9.3f %-10.4f %-6.3f\n', ...
        i, c.Config(1:min(20, length(c.Config))), c.Airfoil, c.AR, c.Score, c.Max_L_D, c.Opt_Alpha, c.CL_at_LD, c.CD_at_LD, c.Cm0);
end
fprintf('=================================================================================================\n\n');

%% 4. Overall Selection Verdict (Winner & Best AR)
best_overall = sorted_configs{1};
fprintf('>>> AERODYNAMIC SELECTION VERDICT <<<\n');
fprintf('  Winning Configuration : %s\n', best_overall.Config);
fprintf('  Winning Airfoil       : %s\n', best_overall.Airfoil);
fprintf('  Optimal Aspect Ratio  : AR = %.2f\n', best_overall.AR);
fprintf('  Peak 3D Glide Ratio   : (CL/CD)_max = %.3f at alpha = %.1f deg\n', best_overall.Max_L_D, best_overall.Opt_Alpha);
fprintf('  Cruise Coefficients   : CL = %.3f, CD = %.4f, Cm0 = %.3f\n', best_overall.CL_at_LD, best_overall.CD_at_LD, best_overall.Cm0);
fprintf('  Composite Score       : %.1f / 100\n\n', best_overall.Score);

%% 5. Export Ranked CSV
csv_out = 'PARAMETRIC_AR_RANKING_RESULTS.csv';
fid = fopen(csv_out, 'w');
if fid ~= -1
    fprintf(fid, 'Rank,Configuration,Airfoil,AR,Score,Max_L_D,Opt_Alpha,CL_at_LD,CD_at_LD,Max_PF,Cm0\n');
    for i = 1:N
        c = sorted_configs{i};
        fprintf(fid, '%d,"%s","%s",%.2f,%.2f,%.3f,%.2f,%.3f,%.4f,%.2f,%.3f\n', ...
            i, c.Config, c.Airfoil, c.AR, c.Score, c.Max_L_D, c.Opt_Alpha, c.CL_at_LD, c.CD_at_LD, c.Max_PF, c.Cm0);
    end
    fclose(fid);
    fprintf('[OK] Full parametric table saved to: %s\n', csv_out);
end

%% 6. Plot AR Sensitivity Curve (L/D vs. AR for Top 3 Airfoils)
unique_foils = unique(cellfun(@(x) string(x.Airfoil), config_list));
figure('Name', 'Glide Ratio vs Aspect Ratio Sensitivity', 'Color', 'w', 'Position', [150, 150, 750, 480]);
hold on; grid on;
palette = [0.000, 0.447, 0.741; 0.850, 0.325, 0.098; 0.466, 0.674, 0.188];

for f_idx = 1:length(unique_foils)
    f_name = unique_foils(f_idx);
    matched = sorted_configs(cellfun(@(x) strcmp(x.Airfoil, f_name) && ~isnan(x.AR), sorted_configs));
    if isempty(matched), continue; end
    
    ars = cellfun(@(x) x.AR, matched);
    lds = cellfun(@(x) x.Max_L_D, matched);
    
    [ars, sort_a] = sort(ars);
    lds = lds(sort_a);
    
    c = palette(mod(f_idx-1, size(palette, 1)) + 1, :);
    plot(ars, lds, '-o', 'Color', c, 'LineWidth', 2.0, 'MarkerFaceColor', c, 'DisplayName', f_name);
end

xlabel('Wing Aspect Ratio (AR)', 'FontSize', 11, 'FontWeight', 'bold');
ylabel('Peak 3D Glide Ratio (C_L / C_D)_{max}', 'FontSize', 11, 'FontWeight', 'bold');
title('Aspect Ratio Sensitivity Sweep (VLM2 Fixed Lift)', 'FontSize', 12, 'FontWeight', 'bold');
legend('Location', 'best', 'FontSize', 10);