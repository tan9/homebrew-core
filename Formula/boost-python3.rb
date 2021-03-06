class BoostPython3 < Formula
  desc "C++ library for C++/Python3 interoperability"
  homepage "https://www.boost.org/"
  url "https://dl.bintray.com/boostorg/release/1.68.0/source/boost_1_68_0.tar.bz2"
  sha256 "7f6130bc3cf65f56a618888ce9d5ea704fa10b462be126ad053e80e553d6d8b7"
  head "https://github.com/boostorg/boost.git"

  bottle do
    sha256 "df9783e900573cefa4eb6f454e2c96af5ba25faf0840c01c0f137b82575c580b" => :mojave
    sha256 "0783713245f6341b55dd0e4bafb2a4783972ed05e4bbd03db0d821c10903aef3" => :high_sierra
    sha256 "064d14b4acde429e7d8713236ebb60f72ae1419cbd84401c7428999118d5d3b5" => :sierra
    sha256 "8a0541752d42846a157b3210db58f6937cd9c0d8eb27731b3538b0523eb16913" => :x86_64_linux
  end

  depends_on "boost"
  depends_on "python"

  resource "numpy" do
    url "https://files.pythonhosted.org/packages/d5/6e/f00492653d0fdf6497a181a1c1d46bbea5a2383e7faf4c8ca6d6f3d2581d/numpy-1.14.5.zip"
    sha256 "a4a433b3a264dbc9aa9c7c241e87c0358a503ea6394f8737df1683c7c9a102ac"
  end

  def install
    # Reduce memory usage below 4 GB for Circle CI.
    jobs = OS.mac? ? ENV.make_jobs : 4

    # "layout" should be synchronized with boost
    args = ["--prefix=#{prefix}",
            "--libdir=#{lib}",
            "-d2",
            "-j#{jobs}",
            "--layout=tagged",
            "--user-config=user-config.jam",
            "threading=multi,single",
            "link=shared,static"]

    # Trunk starts using "clang++ -x c" to select C compiler which breaks C++11
    # handling using ENV.cxx11. Using "cxxflags" and "linkflags" still works.
    args << "cxxflags=-std=c++11"
    if ENV.compiler == :clang
      args << "cxxflags=-stdlib=libc++" << "linkflags=-stdlib=libc++"
    end

    # disable python detection in bootstrap.sh; it guesses the wrong include
    # directory for Python 3 headers, so we configure python manually in
    # user-config.jam below.
    inreplace "bootstrap.sh", "using python", "#using python"

    pyver = Language::Python.major_minor_version "python3"
    if OS.mac?
      py_prefix = Formula["python3"].opt_frameworks/"Python.framework/Versions/#{pyver}"
    else
      py_prefix = Formula["python3"].opt_prefix
    end

    numpy_site_packages = buildpath/"homebrew-numpy/lib/python#{pyver}/site-packages"
    numpy_site_packages.mkpath
    ENV["PYTHONPATH"] = numpy_site_packages
    resource("numpy").stage do
      unless OS.mac?
        openblas = Formula["openblas"].opt_prefix
        ENV["ATLAS"] = "None" # avoid linking against Accelerate.framework
        ENV["BLAS"] = ENV["LAPACK"] = "#{openblas}/lib/libopenblas.so"
        config = <<~EOS
          [openblas]
          libraries = openblas
          library_dirs = #{openblas}/lib
          include_dirs = #{openblas}/include
        EOS
        Pathname("site.cfg").write config
      end
      system "python3", *Language::Python.setup_install_args(buildpath/"homebrew-numpy")
    end

    # Force boost to compile with the desired compiler
    darwin = OS.mac? ? "using darwin : : #{ENV.cxx} ;" : ""
    (buildpath/"user-config.jam").write <<~EOS
      #{darwin}
      using python : #{pyver}
                   : python3
                   : #{py_prefix}/include/python#{pyver}m
                   : #{py_prefix}/lib ;
    EOS

    system "./bootstrap.sh", "--prefix=#{prefix}", "--libdir=#{lib}",
                             "--with-libraries=python", "--with-python=python3",
                             "--with-python-root=#{py_prefix}"

    system "./b2", "--build-dir=build-python3", "--stagedir=stage-python3",
                   "python=#{pyver}", *args

    lib.install Dir["stage-python3/lib/*py*"]
    doc.install Dir["libs/python/doc/*"]
  end

  test do
    (testpath/"hello.cpp").write <<~EOS
      #include <boost/python.hpp>
      char const* greet() {
        return "Hello, world!";
      }
      BOOST_PYTHON_MODULE(hello)
      {
        boost::python::def("greet", greet);
      }
    EOS

    pyincludes = Utils.popen_read("python3-config --includes").chomp.split(" ")
    pylib = Utils.popen_read("python3-config --ldflags").chomp.split(" ")
    pyver = Language::Python.major_minor_version("python3").to_s.delete(".")

    system ENV.cxx, "-shared", *("-fPIC" unless OS.mac?), "hello.cpp", "-L#{lib}", "-lboost_python#{pyver}", "-o",
           "hello.so", *pyincludes, *pylib

    output = <<~EOS
      import hello
      print(hello.greet())
    EOS
    assert_match "Hello, world!", pipe_output("python3", output, 0)
  end
end
