unit class Debian::Package::Raku;

use JSON::Fast;

our sub name-to-debian(Str:D $_ --> Str:D) {
    "raku-" ~ .split('::').join('-').lc
}
sub date-formatter(DateTime:D $_ --> Str:D) {
    sprintf "%s, %02d %s %4d %s %+03d%02d",
            <Mon Tue Wed Thu Fri Sat Sun>[.day-of-week - 1],
            .day,
            <Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec>[.month - 1],
            .year,
            .hh-mm-ss,
            .offset-in-hours, .offset-in-minutes % 60;
            ;
}

has IO:D() $.cache-dir is required;
has IO:D() $.source-dir is required;
has %.ecosystems = cpan => "https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/cpan.json",
                   p6c => "https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/p6c.json",
                   ;

multi method create(::?CLASS:D:
                    Str:D $module,
                    )
{
    my %index = do given self.ecosystems.grep(*<name>.fc eq $module.fc).max(*<version>.Version) {
        when -Inf { die "Module $module not found" }
        default { $_ }
    }
    my $url = %index<source-url> // %index<support><source> // die "Unable to determine download url";
    samewith $module, $url
}
multi method create(::?CLASS:D:
                    Str:D $module,
                    Str:D $url where .ends-with(".tar.gz")
                    )
{
    my $extension = $url.IO.extension(:2parts);
    my $debian-name = name-to-debian $module;
    my $path = $!source-dir.add($debian-name);
    $path.mkdir unless $path.e;
    $path .= add($debian-name);
    if $path.e {
        die "Debian package already exists";
    }
    my $archive = self.download($url, $url.IO.basename);
    run <tar xf>, $archive, "--one-top-level=$path";
    if $path.dir == 1 {
        run 'mv', $path, "$path.tmp";
        run 'mv', "$path.tmp".IO.dir[0], $path;
        run 'rmdir', "$path.tmp";
    }
    my %meta = from-json $path.add("META6.json").slurp;
    my $archive-orig = $path.parent.add("{ $debian-name }_{ %meta<version> }.orig.{ $extension }");
    run 'mv', $archive, $archive-orig;
}
method build(::?CLASS:D:
             IO:D $path,
             )
{
    self.pbuilder($path);
}

method pbuilder(::?CLASS:D:
                IO:D $path,
                Str $dist? is copy,
                )
{
    my IO:D $old-path = $*CWD;
    chdir $path;

    $dist //= 'sid';
    my IO:D $base-file = "/var/cache/pbuilder/base-$dist.tgz".IO;
    unless $base-file.e {
        note "CREATE PBUILDER WITH ", $dist;
        run <sudo -A pbuilder create --basetgz>, $base-file, '--distribution', $dist;
        $!cache-dir.add("install-dh.sh").spurt: "#!/bin/sh\napt install -y debhelper dh-perl6";
        run <sudo -A pbuilder execute --save-after-exec --basetgz>, $base-file, '--distribution', $dist, '--',
                $!cache-dir.add("install-dh.sh");
    }
    if $base-file.modified < now - 60 * 60 {
        note "UPDATE PBUILDER WITH ", $dist;
        run <sudo -A pbuilder update --basetgz>, $base-file, '--distribution', $dist;
    }
    note "BUILD PBUILDER WITH ", $dist;
    run <pdebuild --use-pdebuild-internal -- --basetgz>, $base-file, '--distribution', $dist;
    chdir $old-path;
}

method create-debian(::?CLASS:D:
                     IO:D $path,
                     )
{
    my %meta = from-json $path.add("META6.json").slurp;
    my $debian = $path.add("debian");
    if $debian.e {
        warn "Debian directory already exists";
    }
    $debian.mkdir;
    self.create-debian-changelog: $path, %meta;
    self.create-debian-rules: $path, %meta;
    self.create-debian-control: $path, %meta;
    self.create-debian-source-format: $path, %meta;
    self.create-debian-install: $path, %meta;
}
method create-debian-changelog(::?CLASS:D:
                               IO:D $path,
                               %meta)
{
    my $date = DateTime.now(formatter => &date-formatter);
    my $changelog = $path.add("debian").add("changelog");
    if $changelog.e {
        warn "$changelog already exists";
        return
    }
    $changelog.spurt: qq:to/END/;
{ name-to-debian %meta<name> } ({ %meta<version> }-1) UNRELEASED; urgency=medium

  * Create package for Raku module { %meta<name> }

 -- { %*ENV<DEBFULLNAME> } <{ %*ENV<DEBEMAIL> }>  { $date }
END

}
method create-debian-rules(::?CLASS:D:
                           IO:D $path,
                           %meta)
{
    if 'Build.pm6'.IO.e {
        warn "Build.pm6 exists, this is not supported";
    }
    my $rules = $path.add("debian").add("rules");
    if $rules.e {
        warn "$rules already exists";
        return
    }
    $rules.spurt: q:to/END/;
#!/usr/bin/make -f

%:
	dh $@ --with perl6
END

    run <chmod +x>, $rules;
}
method create-debian-source-format(::?CLASS:D:
                                   IO:D $path,
                                   %meta)
{
    my $format = $path.add("debian").add("source").add("format");
    $path.add("debian").add("source").mkdir;
    if $format.e {
        warn "$format already exists";
        return
    }
    $format.spurt: "3.0 (quilt)";
}

method create-debian-control(::?CLASS:D:
                             IO:D $path,
                             %meta)
{
    my $control = $path.add("debian").add("control");
    if $control.e {
        warn "$control already exists";
        return
    }
    my @build-deps = 'debhelper-compat (= 12)', 'dh-perl6';
    my @deps = 'rakudo', '${misc:Depends}';
    for (|%meta<depends>, |%meta<test-depends>, |%meta<build-depends>) {
        unless $_ ~~ Str:D {
            warn "Unsupported deps: ", $_.raku;
            next;
        }
        @deps.push: name-to-debian $_;
    }
    my $description = qq:to/END/;
Raku module { %meta<name> }
{ %meta<description>.indent(1) }
END

    my @data = [
        [
            Source => name-to-debian(%meta<name>),
            Maintainer => "{ %*ENV<DEBFULLNAME> } <{ %*ENV<DEBEMAIL> }>",
            Section => 'interpreters',
            Priority => 'optional',
            Build-Depends => @build-deps,
            Standards-Version => v4.5.1,
        ], [
            Package => name-to-debian(%meta<name>),
            Architecture => 'all',
            Depends => @deps,
            Description => $description,
        ]
    ];
    $control.spurt: @data.map(*.map({ .key ~ ": " ~ .value.join(", ") }).join("\n")).join("\n\n");
}
method create-debian-install(::?CLASS:D:
                             IO:D $path,
                             %meta)
{
    my $debian-name = name-to-debian %meta<name>;
    my $install = $path.add("debian").add("$debian-name.install");
    if $install.e {
        warn "$install already exists";
        return;
    }
    my @data;
    @data.push: $('lib/*' => "usr/share/perl6/debian-sources/$debian-name/lib") if 'lib'.IO.e;
    @data.push: $('t/*' => "usr/share/perl6/debian-sources/$debian-name/t") if 't'.IO.e;
    @data.push: $("META*" => "usr/share/perl6/debian-sources/$debian-name");
    @data.push: $("README*" => "usr/share/doc/$debian-name/");
    @data.push: $("resources" => "usr/share/perl6/debian-sources/$debian-name") if 'resources'.IO.e;
    @data.push: $("bin/*" => "usr/bin") if 'bin'.IO.e;
    my @supported = |<debian lib t META6.json README README.md resources bin Changes LICENSE>,
                    'xt', #= test for maintainer
                    rx/".iml"$/, '.idea',
                    '.git', '.gitignore',
                    ;
    my @unsupported = $path.dir.grep(-> $i { not any(@supported.map($i.basename ~~*)) });
    if @unsupported {
        warn "Unsupported file : ", @unsupported».basename.join(' ');
    }
    $install.spurt: @data.map({ .key ~ " " ~ .value }).join("\n");

}


method download(::?CLASS:D: Str:D $url, Str:D $fname --> IO:D) {
    my $out = $!cache-dir.add($fname);
    unless $out.e {
        $!cache-dir.mkdir unless $!cache-dir.e;
        run <wget -q>, $url, "-O", $out;
    }
    $out;
}

method ecosystems(::?CLASS:D: --> Seq:D) {
    gather for %!ecosystems.values {
        take $_ for from-json(self.download($_, $_.IO.basename).slurp);
    }
}