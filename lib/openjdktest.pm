# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# Summary: Base module for openJDK test cases
# Maintainer: QE Security <none@suse.de>

package openjdktest;

use base Exporter;
use Exporter;

use consoletest;
use strict;
use warnings;
use testapi;
use utils;

our @EXPORT = qw(
  remove_any_installed_java
  run_crypto_test
  download_and_set_permissions
  prepare_java_ssh_test
  configure_java_version
  run_ssh_test
);

sub remove_any_installed_java {
    my @output = grep /java-\d+-openjdk/, split(/\n/, script_output "rpm -qa 'java-*'");
    return unless scalar @output;    # nothing to remove
    my $pkgs = join ' ', @output;
    zypper_call("rm ${pkgs}");
}

sub configure_java_version {
    my ($version) = @_;
    select_console 'root-console';

    remove_any_installed_java();
    zypper_call("in java-$version-openjdk java-$version-openjdk-devel");

    my $permission = ($version > 15) ? "og+rw" : "og+r";
    assert_script_run("chmod $permission /etc/pki/nssdb/*");

    select_console 'user-console';
    my $vers_file = "/tmp/java_versions_$version.txt";
    script_output("java -version &> $vers_file; javac -version &>> $vers_file");
    validate_script_output("cat $vers_file", sub { m/openjdk version "$version\..*/ });
    validate_script_output("cat $vers_file", sub { m/javac $version\..*/ });
    script_output("rm $vers_file");
}

sub run_crypto_test {
    my ($version) = @_;

    assert_script_run 'curl -O ' . data_url('security/openjdk/GetJCEProviderInfo.java');
    script_run("javac GetJCEProviderInfo.java");
    my $crypto = script_output("java GetJCEProviderInfo");
    record_info("FAIL", "Cannot list all crypto providers", result => 'fail') if ($crypto !~ /Listing all JCA Security Providers/);

    #moved from https://gitlab.suse.de/qe-security/testing/-/raw/main/data/openjdk/Tcheck.java
    my $JDK_TCHECK = get_var("JDK_TCHECK", data_url('security/openjdk/Tcheck.java'));
    assert_script_run("cd ~; test -f Tcheck.java || wget --quiet --no-check-certificate $JDK_TCHECK");
    assert_script_run("javac Tcheck.java");
    # poo125654: we only need to check that '1. SunPKCS11-NSS-FIPS using library null' is present and at the first place
    validate_script_output("java Tcheck", sub { m/.* 1\. SunPKCS11-NSS-FIPS using library null.*/ });
}

sub run_ssh_test {
    my ($version) = @_;

    select_console 'root-console';
    zypper_call('in jsch');

    select_console 'user-console';

    my $java_src = "Shell.java";
    my $url = get_var("TEST_JAVA", data_url("security/openjdk/$java_src"));
    my $cp = script_output('rpm -ql jsch |grep jsch.jar') . ':.';

    script_run("test -f $java_src || wget --quiet --no-check-certificate $url");
    assert_script_run("javac -cp $cp Shell.java");

    select_console 'x11';
    x11_start_program("xterm");
    # wait before typing to avoid typos
    wait_still_screen 5;
    script_run("java -cp $cp Shell", timeout => 0);
    assert_screen "openjdk-hostname";
    for (1 .. 30) { send_key "backspace"; }
    type_string get_var("OPENJDK_HN", 'bernhard@localhost');
    save_screenshot;
    send_key 'ret';
    wait_still_screen 3;
    send_key 'ret';
    save_screenshot;
    wait_still_screen 3;
    send_key 'ret' if (check_screen("auth-key-connect", 10));
    wait_still_screen 3;
    record_info("FAIL", "java.security.ProviderException: Could not derive key", result => 'fail') if (check_screen("shell-not-derive-key", 10));
    send_key 'ret';
    save_screenshot;
    wait_still_screen 3;
    send_key 'alt-f4';
}
