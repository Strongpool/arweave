{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    cmake
    erlang
    gcc
    gmp
    gnumake
    openssl
    rebar3
    openssl
  ];
}
