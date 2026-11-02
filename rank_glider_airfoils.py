import glob
import os
import re

# 1. Directory containing the exported XFLR5 polar files
polar_dir = r"C:\polar_data"
output_all = os.path.join(polar_dir, "ALL_RANKED_AIRFOILS.csv")
output_top10 = os.path.join(polar_dir, "TOP_10_WEIGHTED_AIRFOILS.csv")


def parse_polar_file(filepath):
  foil_name = "Unknown"
  re_val = "Unknown"
  records = []

  try:
    with open(filepath, "r", errors="ignore") as f:
      lines = f.readlines()
  except Exception:
    return None

  # Parse header metadata for airfoil name and Re
  for line in lines[:15]:
    if "Calculated polar for:" in line:
      foil_name = line.replace("Calculated polar for:", "").strip()
    elif "Re =" in line:
      m = re.search(r"Re\s*=\s*([\d\.\s\w]+)", line)
      if m:
        re_val = m.group(1).split()[0].replace(",", "")

  # Fallback to filename if header was generic
  if foil_name == "Unknown" or not foil_name:
    base = os.path.basename(filepath).replace(".txt", "").replace(".plr", "")
    foil_name = re.sub(r"_T\d+_Re.*$", "", base)

  # Extract numerical rows: [Alpha, Cl, Cd, Cdp, Cm]
  for line in lines:
    clean = line.strip()
    if clean and re.match(r"^-?\d+\.\d+", clean):
      parts = [float(v) for v in clean.split()]
      if len(parts) >= 5:
        records.append({
            "alpha": parts[0],
            "cl": parts[1],
            "cd": parts[2],
            "cm": parts[4],
        })

  if len(records) < 4:
    return None

  best_ld = -999.0
  best_alpha = 0.0
  best_cl = 0.0
  best_cd = 0.0
  max_cl = -999.0
  max_pf = -999.0
  cm0 = 0.0
  min_alpha_diff = 999.0

  for r in records:
    a = r["alpha"]
    cl = r["cl"]
    cd = r["cd"]
    cm = r["cm"]

    # Filter for positive physical glide region
    if cd > 0:
      ld = cl / cd
      if ld > best_ld:
        best_ld = ld
        best_alpha = a
        best_cl = cl
        best_cd = cd

      if cl > 0:
        pf = (cl**1.5) / cd
        if pf > max_pf:
          max_pf = pf

    if cl > max_cl:
      max_cl = cl

    # Capture Cm closest to alpha = 0 deg
    if abs(a - 0.0) < min_alpha_diff:
      min_alpha_diff = abs(a - 0.0)
      cm0 = cm

  return {
      "Airfoil": foil_name,
      "Re": re_val,
      "Max_L_D": round(best_ld, 2),
      "Alpha_at_Max_L_D": best_alpha,
      "CL_at_Max_L_D": round(best_cl, 3),
      "CD_at_Max_L_D": round(best_cd, 4),
      "Max_CL": round(max_cl, 3),
      "Max_CL1.5_CD": round(max_pf, 2),
      "Cm0": round(cm0, 3),
      "Valid_Points": len(records),
  }


# 2. Scan and parse all polar text files
all_files = glob.glob(os.path.join(polar_dir, "*.*"))
results = []
for fp in all_files:
  if fp.endswith((".txt", ".plr", ".csv")) and "AIRFOIL" not in fp:
    res = parse_polar_file(fp)
    if res and res["Max_L_D"] > 0:
      results.append(res)

if not results:
  print("No valid polar files found in " + polar_dir)
else:
  # 3. Deduplicate: keep highest Max L/D for each unique airfoil name
  unique_foils = {}
  for item in results:
    name = item["Airfoil"]
    if (
        name not in unique_foils
        or item["Max_L_D"] > unique_foils[name]["Max_L_D"]
    ):
      unique_foils[name] = item

  foils_list = list(unique_foils.values())

  # 4. Normalize metrics (0 to 1 scaling)
  all_ld = [f["Max_L_D"] for f in foils_list]
  all_pf = [f["Max_CL1.5_CD"] for f in foils_list]
  all_cm = [abs(f["Cm0"]) for f in foils_list]

  min_ld, max_ld = min(all_ld), max(all_ld)
  min_pf, max_pf = min(all_pf), max(all_pf)
  min_cm, max_cm = min(all_cm), max(all_cm)

  # Scale metrics and apply composite weighting:
  # 50% Distance + 35% Flight Time + 15% Pitch Trim Stability
  for f in foils_list:
    n_ld = (f["Max_L_D"] - min_ld) / (max_ld - min_ld + 1e-9)
    n_pf = (f["Max_CL1.5_CD"] - min_pf) / (max_pf - min_pf + 1e-9)
    n_cm = 1.0 - ((abs(f["Cm0"]) - min_cm) / (max_cm - min_cm + 1e-9))

    score = (0.50 * n_ld + 0.35 * n_pf + 0.15 * n_cm) * 100.0
    f["Score"] = round(score, 1)

  # 5. Sort all airfoils descending by composite score
  ranked = sorted(foils_list, key=lambda x: x["Score"], reverse=True)

  # 6. Display ALL airfoils in the terminal
  print("\n" + "=" * 88)
  print(
      f"   COMPLETE AIRFOIL RANKING ({len(ranked)} AIRFOILS): 50% DISTANCE /"
      " 35% FLIGHT TIME"
  )
  print("=" * 88)
  header = f"{'Rank':<5} {'Airfoil':<26} {'Score':<8} {'Max L/D':<9} {'Alpha':<7} {'Cl^1.5/Cd':<11} {'Max Cl':<8} {'Cm0':<6}"
  print(header)
  print("-" * 88)

  for i, f in enumerate(ranked, 1):
    name = f["Airfoil"][:24]
    print(
        f"{i:<5} {name:<26} {f['Score']:<8.1f} {f['Max_L_D']:<9.2f}"
        f" {f['Alpha_at_Max_L_D']:<7.1f} {f['Max_CL1.5_CD']:<11.2f}"
        f" {f['Max_CL']:<8.3f} {f['Cm0']:<6.3f}"
    )
    # Add a visual separator after the Top 10
    if i == 10:
      print("-" * 88 + "  [TOP 10 SHORTLIST CUTOFF]")

  print("=" * 88)

  # 7. Export Full Ranking CSV
  with open(output_all, "w") as out:
    out.write(
        "Rank,Airfoil,Score,Max_L_D,Alpha_at_Max_L_D,CL_at_Max_L_D,CD_at_Max_L_D,Max_CL,Max_CL1.5_CD,Cm0,Re\n"
    )
    for i, f in enumerate(ranked, 1):
      out.write(
          f"{i},{f['Airfoil']},{f['Score']},{f['Max_L_D']},{f['Alpha_at_Max_L_D']},{f['CL_at_Max_L_D']},{f['CD_at_Max_L_D']},{f['Max_CL']},{f['Max_CL1.5_CD']},{f['Cm0']},{f['Re']}\n"
      )

  # 8. Export Top 10 CSV
  with open(output_top10, "w") as out:
    out.write(
        "Rank,Airfoil,Score,Max_L_D,Alpha_at_Max_L_D,CL_at_Max_L_D,CD_at_Max_L_D,Max_CL,Max_CL1.5_CD,Cm0,Re\n"
    )
    for i, f in enumerate(ranked[:10], 1):
      out.write(
          f"{i},{f['Airfoil']},{f['Score']},{f['Max_L_D']},{f['Alpha_at_Max_L_D']},{f['CL_at_Max_L_D']},{f['CD_at_Max_L_D']},{f['Max_CL']},{f['Max_CL1.5_CD']},{f['Cm0']},{f['Re']}\n"
      )

  print(f"\n[OK] Complete list ({len(ranked)} airfoils) saved to: {output_all}")
  print(f"[OK] Top 10 candidates saved to: {output_top10}")
