require "minitest/autorun"

class WindowsPathsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WINDOWS = File.join(ROOT, "windows")
  SCRIPTS = Dir[File.join(WINDOWS, "*.ps1")].sort

  def source(name)
    File.read(File.join(WINDOWS, name))
  end

  def resolve(child)
    File.expand_path(child.tr("\\", "/"), WINDOWS)
  end

  def joined_paths(text)
    text.scan(/Join-Path (?:-Path )?\$PSScriptRoot (?:-ChildPath )?'([^']+)'/).flatten
  end

  def test_shared_module_imports
    refute_empty SCRIPTS
    SCRIPTS.each do |path|
      next if File.basename(path) == "create-nat-switch.ps1"

      child = File.read(path)[/^\. \(Join-Path -Path \$PSScriptRoot -ChildPath '([^']+)'\)/, 1]
      refute_nil child, path
      assert_equal File.join(ROOT, "lib/CkaLab.ps1"), resolve(child), path
      assert File.file?(resolve(child)), path
    end
  end

  def test_validator_path
    child = source("Test-CkaLabReady.ps1")[/^\$ScriptPath = Join-Path -Path \$PSScriptRoot -ChildPath '([^']+)'/, 1]
    refute_nil child
    assert_equal File.join(ROOT, "lib/validate-node.sh"), resolve(child)
    assert File.file?(resolve(child))
  end

  def test_c04_working_directories
    scripts = Dir[File.join(WINDOWS, "Initialize-C04*.ps1")]
    assert_equal 3, scripts.length
    scripts.each do |path|
      child = File.read(path)[/^Push-Location \(Join-Path \$PSScriptRoot '([^']+)'\)/, 1]
      refute_nil child, path
      assert_equal ROOT, resolve(child), path
      assert File.file?(File.join(resolve(child), "Vagrantfile")), path
    end
  end

  def test_exercise_paths
    expected_counts = {
      "Invoke-M03Lab.ps1" => 1,
      "Initialize-C04M01Lab.ps1" => 2,
      "Initialize-C04M02Lab.ps1" => 2,
      "Initialize-C04M03Lab.ps1" => 4
    }
    exercise_root = File.expand_path("../../exercise-files", ROOT)
    expected_counts.each do |name, count|
      paths = joined_paths(source(name)).select { |child| child.include?("exercise-files\\") }
      assert_equal count, paths.length, name
      paths.each do |child|
        suffix = child.split("exercise-files\\", 2).last.tr("\\", "/")
        assert_equal File.join(exercise_root, suffix), resolve(child), name
      end
    end
  end

  def test_sibling_wrappers_stay_in_windows
    paths = SCRIPTS.flat_map { |path| joined_paths(File.read(path)) }
      .select { |child| child.end_with?(".ps1") && !child.include?("CkaLab.ps1") }
    refute_empty paths
    paths.each do |child|
      assert_equal WINDOWS, File.dirname(resolve(child)), child
      assert File.file?(resolve(child)), child
    end
  end

  def test_baseline_export_stays_at_lab_root
    child = source("Build-M02UpgradeLab.ps1")[/\$ExportPath = \(Join-Path -Path \$PSScriptRoot -ChildPath '([^']+)'\)/, 1]
    refute_nil child
    assert_equal File.join(ROOT, "baseline-exports"), resolve(child)
  end

  def test_vagrant_windows_trigger
    child = File.read(File.join(ROOT, "Vagrantfile"))[/path: "([^"]+\.ps1)"/, 1]
    refute_nil child
    target = File.expand_path(child, ROOT)
    assert_equal File.join(WINDOWS, "create-nat-switch.ps1"), target
    assert File.file?(target)
  end
end