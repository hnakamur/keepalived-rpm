#!/bin/bash -x
set -eu

copr_project_name=keepalived
rpm_name=keepalived
arch=x86_64

copr_project_description=""

copr_project_instructions="\`\`\`
version=\$(rpm -q --qf "%{VERSION}" \$(rpm -q --whatprovides redhat-release))
\`\`\`

\`\`\`
ver=\${version:0:1}
\`\`\`

\`\`\`
sudo curl -sL -o /etc/yum.repos.d/${COPR_USERNAME}-${copr_project_name}.repo https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/${copr_project_name}/repo/epel-\${ver}/${COPR_USERNAME}-${copr_project_name}-epel-\${ver}.repo
\`\`\`

\`\`\`
sudo yum install ${rpm_name}
\`\`\`"

spec_file=${rpm_name}.spec
mock_chroots="epel-7-${arch}"
ext_repos=""

usage() {
  cat <<'EOF' 1>&2
Usage: build.sh subcommand

subcommand:
  srpm          build the srpm
  mock          build the rpm locally with mock
  copr          upload the srpm and build the rpm on copr
EOF
}

topdir=`rpm --eval '%{_topdir}'`

download_source_files() {
  source_urls=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '/^Source[0-9]*:\s*http/ {print $2}'`
  for source_url in $source_urls; do
    source_file=${source_url##*/}
    (cd ${topdir}/SOURCES && if [ ! -f ${source_file} ]; then curl -sLO ${source_url}; fi)
  done
}

build_srpm() {
  download_source_files
  rpmbuild -bs "${topdir}/SPECS/${spec_file}"
  version=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '$1=="Version:" { print $2 }'`
  release=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '$1=="Release:" { print $2 }'`
  rpm_version_release=${version}-${release}
  srpm_file=${rpm_name}-${rpm_version_release}.src.rpm
}

build_rpm_with_mock() {
  build_srpm
  for mock_chroot in $mock_chroots; do
    /usr/bin/mock -r ${mock_chroot} --rebuild ${topdir}/SRPMS/${srpm_file}

    mock_result_dir=/var/lib/mock/${mock_chroot}/result
    if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${version}-*.${arch}.rpm\" -print -quit`" ]; then
      mkdir -p ${topdir}/RPMS/${arch}
      cp ${mock_result_dir}/${rpm_name}-*${version}-*.${arch}.rpm ${topdir}/RPMS/${arch}/
    fi
    if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${version}-*.noarch.rpm\" -print -quit`" ]; then
      mkdir -p ${topdir}/RPMS/noarch
      cp ${mock_result_dir}/${rpm_name}-*${version}-*.noarch.rpm ${topdir}/RPMS/noarch/
    fi
  done
}

generate_copr_config() {
  mkdir -p $HOME/.config
  cat <<EOF > $HOME/.config/copr
[copr-cli]
username = ${COPR_USERNAME}
login = ${COPR_LOGIN}
token = ${COPR_TOKEN}
copr_url = https://copr.fedoraproject.org
EOF
}

build_rpm_on_copr() {
  build_srpm

  generate_copr_config

  # Create copr project if it does not exist
  if ! copr-cli list-package-names ${COPR_USERNAME}/${copr_project_name} 2>&1; then
    local chroot_args=''
    for mock_chroot in $mock_chroots; do
      chroot_args="$chroot_args --chroot ${mock_chroot}"
    done
    local repo_args=''
    for ext_repo in $ext_repos; do
      repo_args="$repo_args --repo ${ext_repo}"
    done
    copr-cli create --description="${copr_project_description}" \
	--repo "https://copr-be.cloud.fedoraproject.org/results/hnakamur/pcre2/\$chroot/" \
        --instruction="${copr_project_instructions}" $chroot_args $repo_args \
	${COPR_USERNAME}/${copr_project_name}
  fi

  copr-cli build ${COPR_USERNAME}/${copr_project_name} ${topdir}/SRPMS/${srpm_file}
}

case "${1:-}" in
srpm)
  build_srpm
  ;;
mock)
  build_rpm_with_mock
  ;;
copr)
  build_rpm_on_copr
  ;;
coprcfg)
  generate_copr_config
  ;;
*)
  usage
  ;;
esac
