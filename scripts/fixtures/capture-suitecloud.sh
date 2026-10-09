#!/bin/sh
# capture-suitecloud.sh: records real SuiteCloud CLI output for the lens
# fixtures under tests/fixtures/suitecloud/.
#
#   TNS_AUTHID=<sandbox auth id> sh scripts/fixtures/capture-suitecloud.sh
#
# Safety (see the repo's contract): this never deploys, uploads or changes an
# account or the credential store. It refuses to start unless
# `suitecloud account:manageauth --info $TNS_AUTHID` reports an account id
# ending in _SB<n>. Every command runs in scratch projects under
# $TNS_CAPTURE_DIR (default /tmp/tns-suitecloud-capture); the only account
# calls are `project:validate --server`, `object:list` and `file:list`, all
# reads against that sandbox. project:deploy and file:upload fixtures are
# synthetic (tests/fixtures/suitecloud/README.md).
#
# Raw output (ANSI and spinner frames intact) stays in $TNS_CAPTURE_DIR/raw.
# The committed copy is what a Tern lens receives (cursor-to-column-1 and
# carriage returns applied, escape sequences dropped) with the account id,
# account name, domain, auth id, home and scratch paths replaced by
# placeholders. Exit codes go to <name>.exit next to each <name>.txt.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
dest=$repo/tests/fixtures/suitecloud
work=${TNS_CAPTURE_DIR:-/tmp/tns-suitecloud-capture}
cli=${TNS_SUITECLOUD:-suitecloud}
auth=${TNS_AUTHID:-}

die() {
	printf 'capture-suitecloud: %s\n' "$*" >&2
	exit 2
}

[ -n "$auth" ] || die "set TNS_AUTHID to a sandbox auth id (suitecloud account:manageauth --list)"
case $work in
/tmp/* | /private/tmp/*) ;;
*) die "TNS_CAPTURE_DIR must be under /tmp" ;;
esac
command -v "$cli" >/dev/null 2>&1 || die "$cli not found"
command -v perl >/dev/null 2>&1 || die "perl is required to clean the captures"

# The auth id must belong to a sandbox before anything talks to an account.
info=$("$cli" account:manageauth --info "$auth" 2>&1) || die "manageauth --info $auth failed"
plain=$(printf '%s\n' "$info" | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
account=$(printf '%s\n' "$plain" | sed -n 's/^Account ID: *//p' | tr -d '\r ')
name=$(printf '%s\n' "$plain" | sed -n 's/^Account Name: *//p' | sed 's/ *$//')
case $account in
*_[Ss][Bb][0-9]*) ;;
*) die "auth id $auth is not a sandbox (account id '$account'); refusing" ;;
esac
digits=${account%%_*}
[ -n "$digits" ] && [ -n "$name" ] || die "could not read the account id/name of $auth"

rm -rf "$work"
mkdir -p "$work/raw" "$work/proj"
real_work=$(CDPATH='' cd -- "$work" && pwd -P)

# ----------------------------------------------------------------- projects

base() { # dir
	mkdir -p "$1/src/Objects" "$1/src/FileCabinet/SuiteScripts"
	printf "module.exports = {\n\tdefaultProjectFolder: 'src',\n\tcommands: {},\n};\n" >"$1/suitecloud.config.js"
	printf '{\n\t"defaultAuthId": "%s"\n}\n' "$auth" >"$1/project.json"
	cat >"$1/src/manifest.xml" <<'EOF'
<manifest projecttype="ACCOUNTCUSTOMIZATION">
  <projectname>tns-demo</projectname>
  <frameworkversion>1.0</frameworkversion>
  <dependencies>
    <features>
      <feature required="true">SERVERSIDESCRIPTING</feature>
    </features>
  </dependencies>
</manifest>
EOF
	cat >"$1/src/deploy.xml" <<'EOF'
<deploy>
    <files>
        <path>~/FileCabinet/SuiteScripts/*</path>
    </files>
    <objects>
        <path>~/Objects/*</path>
    </objects>
</deploy>
EOF
	cat >"$1/src/Objects/customscript_tns_demo.xml" <<'EOF'
<restlet scriptid="customscript_tns_demo">
  <description></description>
  <isinactive>F</isinactive>
  <name>TNS Demo RESTlet</name>
  <notifyadmins>F</notifyadmins>
  <notifyemails></notifyemails>
  <notifyowner>T</notifyowner>
  <notifyuser>F</notifyuser>
  <scriptfile>[/SuiteScripts/tns_demo.js]</scriptfile>
  <scriptdeployments>
    <scriptdeployment scriptid="customdeploy_tns_demo">
      <allemployees>F</allemployees>
      <allroles>F</allroles>
      <audslctrole></audslctrole>
      <isdeployed>T</isdeployed>
      <loglevel>DEBUG</loglevel>
      <status>TESTING</status>
      <title>TNS Demo RESTlet</title>
    </scriptdeployment>
  </scriptdeployments>
</restlet>
EOF
	cat >"$1/src/FileCabinet/SuiteScripts/tns_demo.js" <<'EOF'
/**
 * @NApiVersion 2.1
 * @NScriptType Restlet
 */
define([], () => ({ get: () => 'ok' }));
EOF
}

edit() { # file perl-expression
	perl -0pi -e "$2" "$1"
}

P=$work/proj
base "$P/clean"
# allpartners depends on the CRM feature the manifest does not declare: a
# warning, not an error.
base "$P/warnings"
edit "$P/warnings/src/Objects/customscript_tns_demo.xml" 's#(      <allemployees>F</allemployees>\n)#$1      <allpartners>F</allpartners>\n#'
base "$P/malformed"
printf '<restlet scriptid="customscript_tns_broken">\n  <name>Broken</name>\n  <scriptfile>[/SuiteScripts/tns_demo.js]</scriptfile>\n</restle>\n' \
	>"$P/malformed/src/Objects/customscript_tns_broken.xml"
base "$P/nodep"
edit "$P/nodep/src/manifest.xml" 's#\n *<feature required="true">SERVERSIDESCRIPTING</feature>##'
base "$P/deploypath"
edit "$P/deploypath/src/deploy.xml" 's#~/FileCabinet/SuiteScripts/\*#~/FileCabinet/SuiteScripts/nope.js#'
base "$P/deploypath-object"
edit "$P/deploypath-object/src/deploy.xml" 's#~/Objects/\*#~/Objects/customscript_tns_nope.xml#'
base "$P/missingfile"
edit "$P/missingfile/src/Objects/customscript_tns_demo.xml" 's#tns_demo\.js#tns_missing.js#'
base "$P/acctref"
edit "$P/acctref/src/manifest.xml" 's#</features>#</features>\n    <objects>\n      <object>customrecord_tns_does_not_exist</object>\n    </objects>#'
base "$P/adddeps"
edit "$P/adddeps/src/manifest.xml" 's#\n *<feature required="true">SERVERSIDESCRIPTING</feature>##'
edit "$P/adddeps/src/Objects/customscript_tns_demo.xml" 's#tns_demo\.js#tns_shared.js#'
mkdir -p "$P/empty"

# ------------------------------------------------------------------ capture

# run NAME DIR ARGS...: runs the CLI in DIR, keeps stdout+stderr interleaved
# as a terminal shows them, records the exit code.
run() {
	n=$1
	d=$2
	shift 2
	printf '  %-40s' "$n"
	mkdir -p "$work/raw/$(dirname -- "$n")"
	set +e
	(cd "$d" && "$cli" "$@") >"$work/raw/$n.txt" 2>&1 </dev/null
	st=$?
	set -e
	printf '%s\n' "$st" >"$work/raw/$n.exit"
	printf 'exit %s\n' "$st"
}

echo "capturing into $work/raw (account $account)"
run help/root "$P/empty" --help
for c in project:validate project:deploy project:package project:adddependencies file:upload account:manageauth; do
	run "help/$(printf '%s' "$c" | tr ':' '-')" "$P/empty" "$c" --help
done

run validate/ok "$P/clean" project:validate
run validate/warnings "$P/warnings" project:validate
run validate/malformed-xml "$P/malformed" project:validate
run validate/missing-dependency "$P/nodep" project:validate
run validate/deploy-path-missing "$P/deploypath" project:validate
run validate/deploy-path-crash "$P/deploypath-object" project:validate
run validate/missing-file "$P/missingfile" project:validate
run validate/log "$P/clean" project:validate --log "$work/validate.log"
run validate/no-account "$P/empty" project:validate

run validate/server-ok "$P/clean" project:validate --server
run validate/server-warnings "$P/warnings" project:validate --server
run validate/server-missing-file "$P/missingfile" project:validate --server
run validate/server-malformed-xml "$P/malformed" project:validate --server
run validate/server-account-dependency "$P/acctref" project:validate --server

run package/ok "$P/clean" project:package
run package/malformed-xml "$P/malformed" project:package
run adddependencies/added "$P/adddeps" project:adddependencies
run adddependencies/none "$P/clean" project:adddependencies

run list/object-none "$P/clean" object:list --scriptid customscript_tns_does_not_exist
run list/file-missing-folder "$P/clean" file:list --folder /SuiteScripts/tns-does-not-exist

# ----------------------------------------------------------------- sanitize

domain_digits=$(printf '%s' "$digits" | tr '[:upper:]' '[:lower:]')
clean() { # raw-file out-file
	TNS_DIGITS=$digits TNS_DOMAIN=$domain_digits TNS_NAME=$name TNS_AUTH=$auth \
		TNS_WORK=$work TNS_REAL_WORK=$real_work TNS_HOME=$HOME perl -e '
		my ($digits, $domain, $name, $auth) = @ENV{qw(TNS_DIGITS TNS_DOMAIN TNS_NAME TNS_AUTH)};
		my @paths = sort { length($b) <=> length($a) } grep { length } @ENV{qw(TNS_REAL_WORK TNS_WORK TNS_HOME)};
		local $/;
		my $text = <STDIN>;
		my @out;
		for my $line (split /\n/, $text, -1) {
			# What Tern hands a lens: the text after the last carriage return
			# or cursor-to-column-1, without escape sequences.
			$line =~ s/.*(?:\r(?!$)|\e\[1?G)//s;
			$line =~ s/\r$//;
			$line =~ s/\e\[[0-9;?]*[A-Za-z]//g;
			$line =~ s/\s+$//;
			for my $p (@paths) {
				my $to = $p eq $ENV{TNS_HOME} ? "/home/dev" : "/work";
				$line =~ s/\Q$p\E/$to/g;
			}
			$line =~ s/\Q$digits\E/1234567/g;
			$line =~ s/\Q$domain\E-/1234567-/g;
			$line =~ s/\Q$name\E/Example Co/g;
			$line =~ s/auth ID "\Q$auth\E"/auth ID "demo-sb"/g;
			push @out, $line;
		}
		print join("\n", @out);
	' <"$1" >"$2"
}

leaks=0
find "$work/raw" -type f -name '*.txt' | LC_ALL=C sort | while IFS= read -r f; do
	rel=${f#"$work/raw/"}
	mkdir -p "$dest/$(dirname -- "$rel")"
	clean "$f" "$dest/$rel"
	cp "${f%.txt}.exit" "$dest/${rel%.txt}.exit"
done
for needle in "$digits" "$name" "$real_work" "$HOME"; do
	if grep -r -l -F -- "$needle" "$dest" >/dev/null 2>&1; then
		grep -r -l -F -- "$needle" "$dest" >&2
		leaks=1
	fi
done
[ "$leaks" = 0 ] || die "unsanitized values remain in the files above"
echo "wrote $dest (run \`make fixtures\`)"
