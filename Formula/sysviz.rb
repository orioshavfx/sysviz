class Sysviz < Formula
  desc "macOS cava alternative: terminal audio visualizer for system audio"
  homepage "https://github.com/orioshavfx/sysviz"
  url "https://github.com/orioshavfx/sysviz/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/orioshavfx/sysviz.git", branch: "main"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/sysviz"
  end

  test do
    assert_path_exists bin/"sysviz"
  end
end
