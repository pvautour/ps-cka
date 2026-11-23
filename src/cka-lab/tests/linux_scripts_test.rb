require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"

class LinuxScriptsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPTS = Dir[File.join(ROOT, "linux", "*.sh")].sort

  def test_every_windows_entry_point_has_a_linux_equivalent
    Dir[File.join(ROOT, "windows", "*.ps1")].each do |windows_script|
      assert File.file?(File.join(ROOT, "linux", File.basename(windows_script, ".ps1") + ".sh"))
    end
  end

  def test_all_shell_files_parse_and_entries_have_help
    Dir[File.join(ROOT, "linux", "**", "*.sh")].each do |script|
      output, status = Open3.capture2e("bash", "-n", script)
      assert status.success?, "#{script}: #{output}"
    end
    SCRIPTS.each do |script|
      output, status = Open3.capture2e("bash", script, "--help", chdir: "/tmp")
      assert status.success?, "#{script}: #{output}"
      assert_includes output, "Usage:"
    end
  end

  def snapshot_fixture(operation, arguments, options = {})
    node_names = JSON.parse(File.read(File.join(ROOT, "lib", "nodes.json"))).map { |node| node.fetch("Name") }
    input = <<~BASH
      set -euo pipefail
      source #{File.join(ROOT, "linux", "lib", "cka.sh").inspect}
      source "$LAB_ROOT/linux/lib/snapshots.sh"
      YES=1
      lab_lock() { :; }
      lab_states() {
        declare -gA LAB_STATES=()
        for target in "${LAB_NODES[@]}"; do LAB_STATES["$target"]=#{options.fetch(:state, "poweroff").inspect}; done
        #{options[:missing_vm] ? 'LAB_STATES["${LAB_NODES[1]}"]=not_created' : ':'}
      }
      lab_domains() { :; }
      lab_snapshot_inventory() {
        declare -gA LAB_SNAPSHOTS=()
        #{options.fetch(:snapshots, node_names).map { |node| "LAB_SNAPSHOTS[#{("#{node}/baseline").inspect}]=1" }.join("\n")}
      }
      lab_vagrant() {
        printf '[CALL]'; printf ' %s' "$@"; printf '\n'
        #{options[:fail_worker] ? '[[ "$*" != "snapshot restore ${LAB_NODES[1]} baseline --no-start --no-provision" ]]' : ':'}
      }
      snapshot_main #{operation} #{arguments}
    BASH
    Open3.capture2e("bash", stdin_data: input)
  end

  def test_restore_preflights_every_snapshot_before_halting
    output, status = snapshot_fixture("Restore", "baseline", snapshots: ["control1", "worker1"])
    refute status.success?
    assert_includes output, "Snapshot missing"
    refute_includes output, "[CALL]"
  end

  def test_missing_vm_prevents_all_changes
    output, status = snapshot_fixture("Save", "fresh", missing_vm: true)
    refute status.success?
    assert_includes output, "Every lab VM must exist"
    refute_includes output, "[CALL]"
  end

  def test_duplicate_save_refuses_before_halt
    output, status = snapshot_fixture("Save", "baseline")
    refute status.success?
    assert_includes output, "Snapshot already exists"
    refute_includes output, "[CALL]"
  end

  def test_restore_is_halted_and_never_automatically_started
    output, status = snapshot_fixture("Restore", "baseline")
    assert status.success?, output
    assert_includes output, "[CALL] halt control1 worker1 worker2"
    assert_equal 3, output.scan("[CALL] snapshot restore").length
    assert_equal 3, output.scan("--no-start --no-provision").length
    refute_includes output, "[CALL] up"
  end

  def test_partial_restore_stops_and_leaves_halted
    output, status = snapshot_fixture("Restore", "baseline", fail_worker: true)
    refute status.success?
    assert_includes output, "All VMs remain halted"
    refute_includes output, "snapshot restore worker2"
    refute_includes output, "[CALL] up"
  end

  def test_dry_run_does_not_halt_or_restore
    output, status = snapshot_fixture("Restore", "baseline --dry-run")
    assert status.success?, output
    assert_includes output, "Would halt"
    refute_includes output, "[CALL]"
  end

  def test_pruning_respects_protected_names
    output, status = snapshot_fixture("Remove", "baseline --keep baseline")
    assert status.success?, output
    assert_includes output, "Protected snapshot skipped"
    refute_includes output, "[CALL]"
  end

  def test_all_workflow_dry_runs_are_offline
    input = <<~BASH
      set -euo pipefail
      source #{File.join(ROOT, "linux", "lib", "cka.sh").inspect}
      vagrant() { printf 'UNEXPECTED VAGRANT CALL\n' >&2; return 99; }
      virsh() { printf 'UNEXPECTED VIRSH CALL\n' >&2; return 99; }
      export -f vagrant virsh
      for script in "$LAB_ROOT"/linux/*.sh; do
        case "$script" in
          *CkaSnapshot.sh) continue ;;
          *Build-M02*) bash "$script" --yes --dry-run ;;
          *) bash "$script" --dry-run ;;
        esac
      done
    BASH
    output, status = Open3.capture2e("bash", stdin_data: input)
    assert status.success?, output
    refute_includes output, "UNEXPECTED"
  end

  def test_readiness_retries_api_and_node_registration
    input = <<~BASH
      set -euo pipefail
      source #{File.join(ROOT, "linux", "lib", "cka.sh").inspect}
      count=0
      kubectl() {
        if [[ "$*" == *--raw=/readyz* ]]; then
          count=$((count + 1))
          [[ $count -ge 2 ]]
        elif [[ "$*" == *'get nodes'* ]]; then
          printf 'node/%s\n' "${LAB_NODES[@]}"
        else printf '[WAIT] %s\n' "$*"; fi
      }
      sleep() { :; }
      lab_command() { eval "$2"; }
      lab_ready
      [[ $count == 2 ]]
    BASH
    output, status = Open3.capture2e("bash", stdin_data: input)
    assert status.success?, output
    assert_equal 3, output.scan("[WAIT]").length
  end

  def test_network_xml_and_gateway_verification
    input = <<~BASH
      set -euo pipefail
      source #{File.join(ROOT, "linux", "lib", "cka.sh").inspect}
      source "$LAB_ROOT/linux/lib/networks.sh"
      lab_virsh() {
        case $1 in
          net-list) : ;;
          net-info) printf 'Active: yes\n' ;;
          net-dumpxml)
            address=172.28.50.1
            [[ $2 != cka-lab ]] || address=192.168.50.1
            printf '<network><name>%s</name><forward mode="nat"/><bridge name="%s"/><ip address="%s" netmask="255.255.255.0"><dhcp><range start="172.28.50.2" end="172.28.50.254"/></dhcp></ip></network>\n' "$2" "$2" "$address" ;;
          *) return 99 ;;
        esac
      }
      lab_require() { :; }
      ip() {
        if [[ "$*" == *'addr show'* ]]; then
          address=172.28.50.1
          [[ ${@: -1} != cka-lab ]] || address=192.168.50.1
          printf '[{"addr_info":[{"local":"%s"}]}]\n' "$address"
        else printf '[]\n'; fi
      }
      lab_network_main create-nat-switch
    BASH
    output, status = Open3.capture2e("bash", stdin_data: input)
    assert status.success?, output
    assert_includes output, "Network checks passed"
  end

  def test_wrong_upgrade_source_stops_before_mutation
    node_records = JSON.parse(File.read(File.join(ROOT, "lib/nodes.json"))).map { |node| "node/#{node.fetch('Name')}" }
    input = <<~BASH
      set -euo pipefail
      source #{File.join(ROOT, "linux", "lib", "cka.sh").inspect}
      kubectl() {
        case "$*" in
          *--raw=/readyz*) : ;;
          *'get nodes -o name'*) printf '%s\n' #{node_records.map(&:inspect).join(' ')} ;;
          *'wait --for=condition=Ready'*) : ;;
          *'get nodes -o json'*) printf '%s\n' '{"items":[{"status":{"nodeInfo":{"kubeletVersion":"v1.35.0"}}},{"status":{"nodeInfo":{"kubeletVersion":"v1.35.0"}}},{"status":{"nodeInfo":{"kubeletVersion":"v1.35.0"}}}]}' ;;
          *) printf 'UNEXPECTED MUTATION: %s\n' "$*" >&2; return 99 ;;
        esac
      }
      vagrant() {
        [[ $1 == ssh ]] || return 99
        bash -se -o pipefail
      }
      sleep() { printf 'Unexpected readiness retry\n' >&2; return 99; }
      export -f kubectl vagrant sleep
      bash "$LAB_ROOT/linux/Invoke-M02Upgrade.sh" --skip-restore --no-auto-snapshot --yes --non-interactive
    BASH
    output, status = Open3.capture2e("bash", stdin_data: input)
    refute status.success?, output
    assert_includes output, "Wrong source kubelet version"
    refute_includes output, "UNEXPECTED MUTATION"
  end

  def test_c04_refreshes_admin_config_and_preserves_unrelated_contexts
    skip "kubectl unavailable for offline config check" unless system("command -v kubectl >/dev/null", exception: false)
    input = "source #{File.join(ROOT, 'linux/lib/cka.sh').inspect}\nsource \"$LAB_ROOT/linux/lib/c04.sh\"\nc04_context_script\n"
    script, status = Open3.capture2e("bash", stdin_data: input)
    assert status.success?, script
    [false, true].each do |existing|
      Dir.mktmpdir do |home|
        admin = File.join(home, "admin.json")
        config = {
          "apiVersion" => "v1", "kind" => "Config", "current-context" => "kubernetes-admin@kubernetes",
          "clusters" => [{"name" => "kubernetes", "cluster" => {"server" => "https://fresh.example:6443"}}],
          "users" => [{"name" => "kubernetes-admin", "user" => {"token" => "fixture-fresh"}}],
          "contexts" => [{"name" => "kubernetes-admin@kubernetes", "context" => {"cluster" => "kubernetes", "user" => "kubernetes-admin"}}]
        }
        File.write(admin, JSON.generate(config))
        if existing
          Dir.mkdir(File.join(home, ".kube"))
          config["clusters"][0]["cluster"]["server"] = "https://stale.example:6443"
          config["users"][0]["user"]["token"] = "fixture-stale"
          config["clusters"] << {"name" => "unrelated", "cluster" => {"server" => "https://other.example:6443"}}
          config["contexts"] << {"name" => "unrelated", "context" => {"cluster" => "unrelated", "user" => "kubernetes-admin"}}
          File.write(File.join(home, ".kube/config"), JSON.generate(config))
        end
        output, status = Open3.capture2e({"HOME" => home, "ADMIN_FIXTURE" => admin}, "bash", stdin_data: "sudo() { cat \"$ADMIN_FIXTURE\"; }\n" + script)
        assert status.success?, output
        output, status = Open3.capture2e({"KUBECONFIG" => File.join(home, ".kube/config")}, "kubectl", "config", "view", "--raw", "-o", "json")
        assert status.success?, output
        result = JSON.parse(output)
        assert_equal "cka-vagrant", result.fetch("current-context")
        assert_equal "https://fresh.example:6443", result.fetch("clusters").find { |cluster| cluster["name"] == "kubernetes" }.fetch("cluster").fetch("server")
        assert_equal "fixture-fresh", result.fetch("users").find { |user| user["name"] == "kubernetes-admin" }.fetch("user").fetch("token")
        assert result.fetch("contexts").any? { |context| context["name"] == "unrelated" } if existing
      end
    end
  end
end