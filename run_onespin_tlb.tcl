# Minimal OneSpin start script for cva6_tlb + package-based scoreboard bind.

set CVA6_RTL_ROOT "/import/lab/users/hassan/Downloads/MasterProjekt/cva6/core"
set WORK_ROOT      "/import/lab/users/hassan/Downloads/MasterProjekt/cva6_tlb_scoreboard"

# 1) Read CVA6 packages first.
read_verilog -sv $CVA6_RTL_ROOT/include/config_pkg.sv
read_verilog -sv $CVA6_RTL_ROOT/include/cv32a60x_config_pkg.sv
read_verilog -sv $CVA6_RTL_ROOT/include/build_config_pkg.sv
read_verilog -sv $CVA6_RTL_ROOT/include/riscv_pkg.sv
read_verilog -sv $CVA6_RTL_ROOT/include/ariane_pkg.sv

# 2) Read our formal package before the top/checker.
read_verilog -sv $WORK_ROOT/cva6_tlb_formal_pkg.sv

# 3) Read DUT, top, and checker.
read_verilog -sv \
  $WORK_ROOT/cva6_tlb.sv \
  $WORK_ROOT/cva6_tlb_formal_top.sv \
  $WORK_ROOT/cva6_tlb_scoreboard_uniqueness_pagesize.sv

# 4) Elaborate the wrapper.
set_elaborate_option -golden -top {Verilog!work.cva6_tlb_formal_top}
elaborate -golden

# 5) Compile formal model.
compile

# 6) Set MV mode.
set_mode mv

# 7) Print available checks.
set all_checks [get_checks]
puts "Available checks:"
foreach c $all_checks {
    puts "  $c"
}

# 8) Run all checks one by one.
foreach c $all_checks {
    puts "============================================================"
    puts "Running check: $c"
    puts "============================================================"
    check -verbose $c
}
