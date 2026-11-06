%% FIXED 3D POLAR RANKING PIPELINE (SHOWING BEST GLIDE OPERATING LIFT)
clear; clc; close all;

data_dir = 'Best3DT2_polars';
if ~exist(data_dir, 'dir')
    error('Folder "%s" not found. Run: unzip(''Best3DT2_polars.zip'', ''Best3DT2_polars''); first.', data_dir);
end

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
    error('No files found inside "%s".', data_dir);
end

plane_map = containers.Map();

%% 1. Parse flow5 3D Files Line by Line
for k = 1:length(file_list)
    fp = file_list{k};
    fid = fopen(fp, 'r');
    if fid == -1, continue; end
    
    plane_name = 'Unknown';
    alphas = []; CLs = []; CDs = []; Cms = [];
    
    first_line = strtrim(fgetl(fid));
    if ischar(first_line) && ~isempty(first_line) && ~contains(first_line, 'Ctrl')
        plane_name = first_line;
    end
    
    if strcmp(plane_name, 'Unknown') || contains(plane_name, 'T2-VLM2')
        [~, base_name, ~] = fileparts(fp);
        plane_name = regexprep(base_name, '_T\d+.*$', '');
    end
    
    while ~feof(fid)
        tline = strtrim(fgetl(fid));
        if isempty(tline), continue; end
        
        tokens = strsplit(tline);
        % Line 1 starts with '0' (Ctrl)
        if length(tokens) >= 12 && strcmp(tokens{1}, '0')
            a_val  = str2double(tokens{2});
            cl_val = str2double(tokens{5});
            cd_val = str2double(tokens{6});
            cm_val = str2double(tokens{10});
            
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
    
    % Zero-lift pitch moment closest to alpha = 0 deg
    [~, idx_cm0]     = min(abs(alphas - 0.0));
    cm0_val          = Cms(idx_cm0);
    
    if ~isKey(plane_map, plane_name) || max_ld > plane_map(plane_name).Max_L_D
        entry.Name        = plane_name;
        entry.Max_L_D     = round(max_ld, 3);
        entry.Alpha_L_D   = alphas(idx_ld);
        entry.CL_at_LD    = round(CLs(idx_ld), 3); % Operating lift at best glide!
        entry.CD_at_LD    = round(CDs(idx_ld), 4); % Operating drag at best glide!
        entry.Max_PF      = round(max_pf, 2);
        entry.Cm0         = round(cm0_val, 3);
        entry.alpha       = alphas;
        entry.CL          = CLs;
        entry.CD          = CDs;
        entry.Cm          = Cms;
        entry.LD          = LDs;
        plane_map(plane_name) = entry;
    end
end

keys = plane_map.keys();
if isempty(keys)
    error('Could not extract valid data points.');
end

N = length(keys);
records = cell(N, 1);
for i = 1:N
    records{i} = plane_map(keys{i});
end

all_ld  = cellfun(@(x) x.Max_L_D, records);
all_pf  = cellfun(@(x) x.Max_PF, records);
all_cm0 = abs(cellfun(@(x) x.Cm0, records));

norm_ld  = (all_ld - min(all_ld)) ./ (max(all_ld) - min(all_ld) + eps);
norm_pf  = (all_pf - min(all_pf)) ./ (max(all_pf) - min(all_pf) + eps);
norm_cm  = 1.0 - ((all_cm0 - min(all_cm0)) ./ (max(all_cm0) - min(all_cm0) + eps));

% 50% Distance + 35% Flight Time + 15% Pitch Trim Penalty
for i = 1:N
    records{i}.Score = (0.50 * norm_ld(i) + 0.35 * norm_pf(i) + 0.15 * norm_cm(i)) * 100;
end

[~, sort_idx] = sort(cellfun(@(x) x.Score, records), 'descend');
sorted_planes = records(sort_idx);

%% 2. Display Table (Showing True Cruise / Best Glide Values)
fprintf('\n=========================================================================================\n');
fprintf('Rank  Glider Profile / AR         Score   3D Max L/D  Opt Alpha   CL @ Max L/D  CD @ Max L/D  Cm0\n');
fprintf('=========================================================================================\n');
num_top = min(10, length(sorted_planes));
for i = 1:num_top
    p = sorted_planes{i};
    fprintf('%-5d %-26s %-7.1f %-11.3f %-11.1f %-13.3f %-13.4f %-6.3f\n', ...
        i, p.Name(1:min(25, length(p.Name))), p.Score, p.Max_L_D, p.Alpha_L_D, p.CL_at_LD, p.CD_at_LD, p.Cm0);
end
fprintf('=========================================================================================\n\n');

%% 3. Export CSV
csv_out = 'TOP_10_3D_RANKED_GLIDERS.csv';
fid = fopen(csv_out, 'w');
if fid ~= -1
    fprintf(fid, 'Rank,Configuration,Score,3D_Max_L_D,Alpha_at_Max_L_D,CL_at_Max_L_D,CD_at_Max_L_D,3D_Max_CL1.5_CD,Cm0\n');
    for i = 1:num_top
        p = sorted_planes{i};
        fprintf(fid, '%d,"%s",%.2f,%.3f,%.2f,%.3f,%.4f,%.2f,%.3f\n', ...
            i, p.Name, p.Score, p.Max_L_D, p.Alpha_L_D, p.CL_at_LD, p.CD_at_LD, p.Max_PF, p.Cm0);
    end
    fclose(fid);
    fprintf('[OK] 3D Ranked table successfully exported to: %s\n', csv_out);
end