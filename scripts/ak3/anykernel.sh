## AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=FinaSU for odin (kaixin886/odin-kernel)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=odin
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
block=/dev/block/by-name/boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
no_magisk_check=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# boot install
dump_boot; # use split_boot to skip ramdisk unpack, or push_ramdisk to skip further unpack

# begin ramdisk changes

# end ramdisk changes

write_boot; # use flash_boot to skip ramdisk repack, or block=/dev/block/by-name/<partition> and flash_boot for a partition not named "boot"
## end boot install
