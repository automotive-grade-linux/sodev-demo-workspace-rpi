SUMMARY = "Source tree for the trout AGL host services (fetch-only, shared)"
DESCRIPTION = "\
    Fetches the 14 public git sources that device/google/trout's \
    agl_services_build needs, and reproduces the <linkfile> layout its \
    repo_manifest.xml would create. Fetch-only: the native and target builds \
    both compile out of this one work-shared checkout. \
    "

SRCREV_FORMAT = "default"

deltask do_configure
deltask do_compile
deltask do_install
deltask do_populate_lic
deltask do_populate_sysroot

inherit nopackages

# Shared across the native and target recipes so the 14 repos are fetched once.
WORKDIR = "${TMPDIR}/work-shared/google-trout-agl-services-source/${PV}-${PR}"

require trout-sources.inc
