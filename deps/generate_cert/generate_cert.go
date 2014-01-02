package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"os"
	"time"
)

func mustNoErr(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

var earlyNotBefore = time.Date(2013, 1, 1, 0, 0, 0, 0, time.UTC)

// that's max date that current golang x509 code supports
var earlyNotAfter = time.Date(2049, 12, 31, 23, 59, 59, 0, time.UTC)

func pemIfy(octets []byte, pemType string, out io.Writer) {
	pem.Encode(out, &pem.Block{
		Type:  pemType,
		Bytes: octets,
	})
}

func main() {
	pkey, err := rsa.GenerateKey(rand.Reader, 2048)
	mustNoErr(err)

	template := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		NotBefore: earlyNotBefore,
		NotAfter: earlyNotAfter,
		Subject: pkix.Name{
			CommonName: "*",
		},
	}

	certDer, err := x509.CreateCertificate(rand.Reader, &template, &template, &pkey.PublicKey, pkey)
	mustNoErr(err)

	pemIfy(certDer, "CERTIFICATE", os.Stdout)
	pemIfy(x509.MarshalPKCS1PrivateKey(pkey), "RSA PRIVATE KEY", os.Stdout)
}
