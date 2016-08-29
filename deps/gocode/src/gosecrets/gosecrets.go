package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"errors"
	"fmt"
	"golang.org/x/crypto/pbkdf2"
	"io"
	"os"
)

const keySize = 32
const nIterations = 4096

var hmacFun = sha1.New

var salt = [8]byte{20, 183, 239, 38, 44, 214, 22, 141}

type encryptionService struct {
	lockKey          []byte
	encryptedDataKey []byte
	reader           *bufio.Reader
}

func main() {
	s := &encryptionService{
		reader: bufio.NewReader(os.Stdin),
	}
	for {
		s.processCommand()
	}
}

func (s *encryptionService) readCommand() (byte, []byte) {
	var size uint16
	err := binary.Read(s.reader, binary.BigEndian, &size)
	if err != nil {
		processReadError(err)
	}
	if size < 1 {
		panic("Command is too short")
	}
	command, err := s.reader.ReadByte()
	if err != nil {
		processReadError(err)
	}
	if size == 1 {
		return command, nil
	}
	buf := make([]byte, size-1)
	n, err := s.reader.Read(buf)
	if err != nil {
		processReadError(err)
	}
	if uint16(n) != size-1 {
		panic("Error reading input")
	}
	return command, buf
}

func processReadError(err error) {
	if err == io.EOF {
		// parent died. close normally
		os.Exit(0)
	}
	panic(fmt.Sprintf("Error reading input %v", err))
}

func doReply(data []byte) {
	err := binary.Write(os.Stdout, binary.BigEndian, uint16(len(data)))
	if err != nil {
		panic(fmt.Sprintf("Error writing data %v", err))
	}
	os.Stdout.Write(data)
}

func replySuccessWithData(data []byte) {
	doReply(append([]byte{'S'}, data...))
}

func replySuccess() {
	doReply([]byte{'S'})
}

func replyError(error string) {
	doReply([]byte("E" + error))
}

func (s *encryptionService) processCommand() {
	command, data := s.readCommand()

	switch command {
	case 1:
		s.cmdSetPassword(data)
	case 2:
		s.cmdCreateDataKey()
	case 3:
		s.cmdSetDataKey(data)
	case 4:
		s.cmdGetDataKey()
	case 5:
		s.cmdEncrypt(data)
	case 6:
		s.cmdDecrypt(data)
	default:
		panic(fmt.Sprintf("Unknown command %v", command))
	}
}

func (s *encryptionService) cmdSetPassword(data []byte) {
	s.lockKey = pbkdf2.Key(data, salt[:], nIterations, keySize, hmacFun)
	replySuccess()
}

func (s *encryptionService) cmdCreateDataKey() {
	if s.lockKey == nil {
		panic("Password was not set")
	}
	dataKey := make([]byte, keySize)
	if _, err := io.ReadFull(rand.Reader, dataKey); err != nil {
		panic(err.Error())
	}
	encryptedDataKey := aesgcmEncrypt(s.lockKey, dataKey)
	replySuccessWithData(encryptedDataKey)
}

func (s *encryptionService) cmdSetDataKey(data []byte) {
	if s.lockKey == nil {
		panic("Password was not set")
	}
	_, err := aesgcmDecrypt(s.lockKey, data)
	if err != nil {
		replyError(err.Error())
		return
	}
	s.encryptedDataKey = data
	replySuccess()
}

func (s *encryptionService) cmdGetDataKey() {
	replySuccessWithData(s.encryptedDataKey)
}

func (s *encryptionService) cmdEncrypt(data []byte) {
	if s.lockKey == nil {
		panic("Password was not set")
	}
	dataKey, err := aesgcmDecrypt(s.lockKey, s.encryptedDataKey)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccessWithData(aesgcmEncrypt(dataKey, data))
}

func (s *encryptionService) cmdDecrypt(data []byte) {
	if s.lockKey == nil {
		panic("Password was not set")
	}
	dataKey, err := aesgcmDecrypt(s.lockKey, s.encryptedDataKey)
	if err != nil {
		replyError(err.Error())
		return
	}
	plaintext, err := aesgcmDecrypt(dataKey, data)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccessWithData(plaintext)
}

func aesgcmEncrypt(key []byte, data []byte) []byte {
	block, err := aes.NewCipher(key)
	if err != nil {
		panic(err.Error())
	}
	aesgcm, err := cipher.NewGCM(block)
	if err != nil {
		panic(err.Error())
	}

	nonce := make([]byte, aesgcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		panic(err.Error())
	}
	return aesgcm.Seal(nonce[:aesgcm.NonceSize()], nonce, data, nil)
}

func aesgcmDecrypt(key []byte, data []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		panic(err.Error())
	}
	aesgcm, err := cipher.NewGCM(block)
	if err != nil {
		panic(err.Error())
	}

	if len(data) < aesgcm.NonceSize() {
		return nil, errors.New("ciphertext is too short")
	}
	nonce := data[:aesgcm.NonceSize()]
	data = data[aesgcm.NonceSize():]

	return aesgcm.Open(nil, nonce, data, nil)
}
