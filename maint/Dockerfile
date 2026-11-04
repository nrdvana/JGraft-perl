# This docker image contains everything needed for development and testing
# of the library. It includes system Perl, Perl 5.8 for back-compat tests,
# and Perl 5.28 for testing the modern/legacy source boundary.

FROM debian:13

RUN apt-get update && apt-get install -y \
      ca-certificates fontconfig \
      bzip2 gzip unzip zip curl gosu jq lsof procps git \
      gcc-12 libc6-dev make patch \
      perl libdatetime-perl libpath-tiny-perl libio-all-perl libtest2-suite-perl \
      libdist-zilla-perl libdist-zilla-plugin-git-perl \
      libdist-zilla-plugin-ourpkgversion-perl libdist-zilla-plugin-podweaver-perl \
      libdist-zilla-plugin-makemaker-awesome-perl \
      libtest-pod-perl libtest-pod-coverage-perl libpod-coverage-trustpod-perl \
 && ln -s /usr/bin/gcc-12 /usr/local/bin/gcc \
 && rm -rf /var/lib/apt/lists/*

# Use GCC 12 for the legacy Configure probes, which predate GCC 14's stricter
# errors. PatchPerl handles other changes in modern compilers and libc.
# Its Linux library search invokes gcc even when Configure uses -Dcc=gcc-12,
# so provide that name too, or it will miss Debian's multiarch libraries.
# Bootstrap with the standalone cpanm: Debian's cpanm uses system Perl modules
# that would not be visible to the separate Perl 5.8 installation.
# Test2's tests need parent. Bootstrap with a release whose tests work with
# Perl 5.8's bundled Test::More, before Test2 installs the newer Test::More.
# Perl 5.28's bundled MakeMaker needs upgrading for the project's Makefile.PL.
# Test::Pod::Coverage::Configurable is the author plugin not packaged by Debian.
RUN cd /tmp \
 && curl -fL https://cpan.metacpan.org/authors/id/M/MI/MIYAGAWA/App-cpanminus-1.7048.tar.gz \
      -o cpanminus.tar.gz \
 && echo '59b60907ab9fa4f72ca2004fbe6054911439ae9a906890b4d842a87b25f20f3c  cpanminus.tar.gz' \
      | sha256sum -c - \
 && tar xzf cpanminus.tar.gz \
 && perl App-cpanminus-1.7048/bin/cpanm --mirror https://cpan.metacpan.org --mirror-only \
      Devel::PatchPerl@2.14 Dist::Zilla::Plugin::Test::Pod::Coverage::Configurable \
 && curl -fL https://www.cpan.org/src/5.0/perl-5.8.9.tar.gz -o perl-5.8.9.tar.gz \
 && echo '60dfe024286299b547895b6bc8f41c20c7e83d292f3a406e113ba1951aa38da1  perl-5.8.9.tar.gz' \
      | sha256sum -c - \
 && tar xzf perl-5.8.9.tar.gz \
 && cd perl-5.8.9 \
 && patchperl \
 && sh Configure -des -Dprefix=/opt/perl-5.8.9 -Dcc=gcc-12 \
 && make -j2 \
 && make install \
 && cd /tmp \
 && /opt/perl-5.8.9/bin/perl App-cpanminus-1.7048/bin/cpanm \
      --mirror https://cpan.metacpan.org --mirror-only App::cpanminus \
      https://cpan.metacpan.org/authors/id/C/CO/CORION/parent-0.238.tar.gz Test2::V0 Time::Piece \
 && ln -s /opt/perl-5.8.9/bin/perl /usr/local/bin/perl5.8 \
 && ln -s /opt/perl-5.8.9/bin/prove /usr/local/bin/prove5.8 \
 && perl5.8 -MTest2::V0 -e 'is(sprintf("%vd", $^V), "5.8.9", "legacy interpreter"); done_testing;' \
 && cd /tmp \
 && curl -fL https://www.cpan.org/src/5.0/perl-5.28.3.tar.gz -o perl-5.28.3.tar.gz \
 && echo 'afc9c1d661597ae14d9e883c5071092bed73f60c3109b294823ea01aca705114  perl-5.28.3.tar.gz' \
      | sha256sum -c - \
 && tar xzf perl-5.28.3.tar.gz \
 && cd perl-5.28.3 \
 && patchperl \
 && sh Configure -des -Dprefix=/opt/perl-5.28.3 -Dcc=gcc-12 \
 && make -j2 \
 && make install \
 && cd /tmp \
 && /opt/perl-5.28.3/bin/perl App-cpanminus-1.7048/bin/cpanm \
      --mirror https://cpan.metacpan.org --mirror-only \
      App::cpanminus ExtUtils::MakeMaker Test2::V0 \
 && ln -s /opt/perl-5.28.3/bin/perl /usr/local/bin/perl5.28 \
 && ln -s /opt/perl-5.28.3/bin/prove /usr/local/bin/prove5.28 \
 && perl5.28 -MExtUtils::MakeMaker=7.70 -MTest2::V0 \
      -e 'is(sprintf("%vd", $^V), "5.28.3", "modern branch boundary interpreter"); done_testing;' \
 && rm -rf /tmp/perl-5.8.9 /tmp/perl-5.8.9.tar.gz \
      /tmp/perl-5.28.3 /tmp/perl-5.28.3.tar.gz \
      /tmp/App-cpanminus-1.7048 /tmp/cpanminus.tar.gz /root/.cpanm

# Run tests with: perl5.8 Makefile.PL && make test
#             or perl5.28 Makefile.PL && make test
# Or invoke the versioned perl/prove aliases directly. System Perl remains default.
